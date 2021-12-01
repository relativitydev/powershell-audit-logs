<#
.SYNOPSIS
    Retrieves all audits for actions by Relativity employees in customer workspaces within a specified time range

.DESCRIPTION 
    Retrieves all audits for actions by Relativity employees in customer workspaces within a specified time range. Searches for all audits from users with "@relativity.com" email addresses in all workspaces, excluding automation/system emails and automation/support workspaces. Produces a JSON list of audits, including Audit ID, timestamp, action type, and workspace.

.PARAMETER restUri
    Specifies the base URI of the Relativity instance to query 

.PARAMETER restUserName
    Specifies the username of a Relativity account to use to query for audits. Account should have permission to query for Users, Workspaces, and Audits

.PARAMETER restPassword
    Specifies the password of a Relativity account to use to query for audits, supplied as a Powershell SecureString

.PARAMETER lowerRangeDate
    Specifies the earliest date to search, written as YYYY-MM-DD. Search begins at 00:00 UTC on the specified day

.PARAMETER upperRangeDate
    Specifies the latest date to search, written as YYYY-MM-DD. Search ends at 11:59 UTC on the specified day

.PARAMETER groupByWorkspace
    (Optional) Include this flag to group audit events by the workspace the event occurred within. Cannot be combined with other groupBy parameters.

.PARAMETER groupByUser
    (Optional) Include this flag to group audit events by the User Name each action was taken by.  Cannot be combined with other groupBy parameters.

.PARAMETER groupByAction
    (Optional) Include this flag to group audit events by the audit Action type. Cannot be combined with other groupBy parameters.

.PARAMETER getAdminCaseAudits
    (Optional) Include this flag to show audits that took place in the Admin Case configuration workspace. 
    This will show audits for system configuration changes such as Login events, User and Group object creations or changes, and Instance Setting modifications.
    NOTE: Including this flag will greatly increase the number of audit entries in the results.

NOTES:
    - The restUserName and restPassword need to be for an account which has both Audit API access, such as System Administrator group members, and a Password Login Method.
    - To capture all events up to the script run time, it is recommended that the upperRangeDate parameter be set to tomorrow's date.
    - Both the $lowerRangeDate and $upperRangeDate are in UTC time.
    - The required script execution time is in proportion to the number of Relativity Employee user accounts in the R1 environment and the number of audits found. 
    - Disclaimer for RelativityOne environment usage:
        - This script is limited to public Audit APIs for retrieving audit events.
        - Due to technical limitations of the public Audit APIs and the automatic deletion of Relativity Employee accounts, audits of Relativity Employees are only 
          available via this script for as long as the employee accounts exist in the Relativity environment. Once a Relativity Employee account has been deleted, this script
          is unable to retrieve their audited events.
        - As a result, it is recommended that the script be run at least daily to capture Relativity Employee audits before the user accounts are removed. 
          It is recommended the script be run with a $lowerRangeDate set to yesterday, and the $upperRangeDate set to today every 12 hours.
          The script can be run as often as desired to ensure all Relativity Employee access is captured.

EXAMPLE POWERSHELL USAGE
    > cd <script dir>
    > . .\Get-LockboxAudits.ps1 
    > Get-Help  Get-Audits-For-Users-In-Workspace -detailed
    > $SecureStringPassword = Read-Host -AsSecureString
    > <enter password for Relativity account>
    > $restUri = "https://my.relativity.baseurl"
    > $restUserName = "admin.account@relativity.com"
    > $lowerRangeDate = "2021-10-27"
    > $upperRangeDate = '2021-10-29"
    Example Use 1: Output Audits to Console, grouped by Workspace: 
    > Get-Audits-For-Users-In-Workspace -restUri $restUri -restUserName $restUserName -restPassword $SecureStringPassword -lowerRangeDate $lowerRangeDate -upperRangeDate $upperRangeDate -groupByWorkspace
    Example Use 2: Group audits by User Name, including audits for the Admin Case, and Save Audits to a .csv file:
    > Get-Audits-For-Users-In-Workspace -restUri $restUri -restUserName $restUserName -restPassword $SecureStringPassword -lowerRangeDate $lowerRangeDate -upperRangeDate $upperRangeDate -groupByUser -getAdminCaseAudits | Out-File -FilePath .\Audits.csv
    Example Use 3: Group audits by Audit Action Type, including audits for the Admin Case, and Save Audits to a .csv file:
    > Get-Audits-For-Users-In-Workspace -restUri $restUri -restUserName $restUserName -restPassword $SecureStringPassword -lowerRangeDate $lowerRangeDate -upperRangeDate $upperRangeDate -groupByAction -getAdminCaseAudits | Out-File -FilePath .\Audits.csv
#>

function Get-Audits-For-Users-In-Workspace{
         param (
        [Parameter(Mandatory)]
        [string]
        $restUri,

        [Parameter(Mandatory)]
        [string]
        $restUserName,

        [Parameter(Mandatory)]
        [SecureString]
        $restPassword,

        [Parameter(Mandatory)]
        [string]
        $lowerRangeDate,

        [Parameter(Mandatory)]
        [string]
        $upperRangeDate,

        [Switch]$groupByWorkspace,

        [Switch]$groupByUser,

        [Switch]$groupByAction,

        [Switch]$getAdminCaseAudits

    )
            Write-Host "Executing script"        

            $credentials = New-Object System.Management.Automation.PSCredential -ArgumentList $restUserName, $restPassword
            $authHeader = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $restUserName, $credentials.GetNetworkCredential().Password)))

            $stopLoop = $false
            [int]$retryCount = 0

            Write-Host "Gathering users for query"

            $userAPIEndpoint = "/Relativity.REST/api/Relativity-Identity/v1/workspaces/-1/query-users"
            $userExcludeNames = @("automatedworkflows@relativity.com", "automation.serviceaccount@relativity.com", "clowder@relativity.com", "conversionpasswords@relativity.com", "newrelicsynthetics@relativity.com", "relativity.admin@relativity.com", "relativity.serviceaccount@relativity.com", "serviceaccount@relativity.com", "smoketestuser@relativity.com")
            $userExcludeList =  ($userExcludeNames | Select-Object @{name="Clause";expression= {"'Email' <> '$($_.FullName)'"}}).Clause -join " AND "
            $usernameBody = @{
                "Query" = @{
                    "Condition" = "'Email' LIKE '%@relativity.com' AND $userExcludeList"
                }
                "Start" = 0
                "Length" = 10000
            } | ConvertTo-Json -Depth 3

            $userNames = @()
            do {
                try {
                    $queryResponse = Invoke-RestMethod $restUri$userAPIEndpoint -Headers @{ Authorization = "Basic $authHeader"; "X-CSRF-Header" = ""; "Content-Type" = "application/json;charset=UTF-8"} -Method POST -Body $usernameBody 
                    $userNames = $queryResponse.DataResults | Select-Object -Property FullName
                    $stopLoop = $true  
                }
                catch {
                    if ($retryCount -gt 3){
                        Write-Host "Could not send Information after 4 retrys."
                        Write-host "Exception: $_"
                        Write-Host "POST body: " $usernameBody
                        $stopLoop = $true
                    }
                    else {
                        Write-Host "Could not get query response retrying in 30 seconds..."
                        Write-host "Exception: $_"
                        Start-Sleep -Seconds 30
                        $retryCount = $retryCount + 1
                    }
                }
            } while ($stopLoop -eq $false)
            $retryCount = 0
            $stopLoop = $false

            #update user names that contain a single quote so that they do not cause user ID choice query string syntax errors
            foreach($userName in $userNames) {
                $userName.FullName =  $userName.FullName -Replace "[']","\\'"
            }

            $totalNames = $userNames.Count
            $chunkSize = 950
            $totalNameChunks = [Math]::Ceiling($totalNames / $chunkSize)

            if ($chunkSize -lt $totalNames) { 
                $userNamesChunks = for ($i = 1; $i -le $totalNameChunks; $i++) {
                    $first = (($i - 1) * $chunkSize)
                    $last  = [Math]::Min(($i * $chunkSize) - 1, $totalNames - 1)
                    ,$userNames[$first..$last]
                }
            } else {
                $userNamesChunks = @($userNames)
            }

            Write-Host "Generating audit query from users"

            [System.Collections.ArrayList]$choices = @()

            foreach($userNamesChunk in $userNamesChunks) {
                $choiceAPIEndpoint = "/Relativity.Rest/api/Relativity.Services.ChoiceQuery.IChoiceQueryModule/Choice Query Manager/QueryAsync"
                $choiceNameList =  ($userNamesChunk | Select-Object @{name="Clause";expression= {"'Name' == '$($_.FullName)'"}}).Clause -join " OR "
                $choiceBody = @{
                    "workspaceId" = -1
                    "request" = @{
                        "Condition" = $choiceNameList
                        "objectType" = @{
                            "Name" = "Data Grid Audit"
                        }
                    }
                    "Start" = 0
                    "Length" = 10000
                } | ConvertTo-Json -Depth 5 | ForEach-Object { [System.Text.RegularExpressions.Regex]::Unescape($_) }
    
                do {
                    try {
                        $queryResponse = Invoke-RestMethod $restUri$choiceAPIEndpoint -Headers @{ Authorization = "Basic $authHeader"; "X-CSRF-Header" = ""; "Content-Type" = "application/json;charset=UTF-8"} -Method POST -Body $choiceBody 
                        $currentChoices = $queryResponse.Objects | Select-Object -Property ArtifactID
                        foreach($choice in $currentChoices) {
                            $choices.Add($choice) | Out-Null
                        }
                        $stopLoop = $true  
                    }
                    catch {
                        if ($retryCount -gt 3){
                            Write-Host "Could not send Information after 4 retrys."
                            Write-host "Exception: $_"
                            Write-Host "POST body: " $choiceBody
                            $stopLoop = $true
                        }
                        else {
                            Write-Host "Could not get query response. retrying in 30 seconds..."
                            Write-host "Exception: $_"
                            Start-Sleep -Seconds 30
                            $retryCount = $retryCount + 1
                        }
                    }
                } while ($stopLoop -eq $false)
                $retryCount = 0
                $stopLoop = $false
            }

            Write-Host "Querying for workspaces to exclude"

            if ($getAdminCaseAudits.IsPresent) {
                Write-Host "Admin Case audits will be included in the results"
                $workspaceExcludeNames = @("[DO NOT ACCESS] - RelativityOne Automation", "[DO NOT ACCESS] - RelativityOne Maintenance", "[DO NOT ACCESS] - RelativityOne Template",	"New Case Template", "Relativity Starter Template")
            }
            else {
                Write-Host "Admin Case audits will not be included in the results"
                $workspaceExcludeNames = @("[DO NOT ACCESS] - RelativityOne Automation", "[DO NOT ACCESS] - RelativityOne Maintenance", "[DO NOT ACCESS] - RelativityOne Template",	"New Case Template", "Relativity Starter Template", "Admin Case") 
            }
            
            $workspaceExcludeString = ($workspaceExcludeNames | Select-Object  @{name="Clause";expression= {"'Name' == '$_'"}}).Clause -join " OR "
            $workspaceBody = @{
                "workspaceId" = -1
                "request" = @{
                    "Condition" = $workspaceExcludeString
                    "objectType" = @{
                        "Name" = "Data Grid Audit"
                    }
                }
                "Start" = 0
                "Length" = 10000
            } | ConvertTo-Json -Depth 5 | ForEach-Object { [System.Text.RegularExpressions.Regex]::Unescape($_) }

            $workspaceChoices = @()
            do {
                try {
                    $queryResponse = Invoke-RestMethod $restUri$choiceAPIEndpoint -Headers @{ Authorization = "Basic $authHeader"; "X-CSRF-Header" = ""; "Content-Type" = "application/json;charset=UTF-8"} -Method POST -Body $workspaceBody 
                    $workspaceChoices = $queryResponse.Objects.ArtifactID 
                    $stopLoop = $true  
                }
                catch {
                    if ($retryCount -gt 3){
                        Write-Host "Could not send Information after 4 retrys."
                        Write-Host "POST body: " $workspaceBody
                        $stopLoop = $true
                    }
                    else {
                        Write-Host "Could not get response retrying in 30 seconds..."
                        Start-Sleep -Seconds 30
                        $retryCount = $retryCount + 1
                    }
                }
            } while ($stopLoop -eq $false)
            $retryCount = 0
            $stopLoop = $false

            Write-Host "Querying for audits"

            $totalChoices = $choices.Count
            $chunkSize = 500
            $totalChoiceChunks = [Math]::Ceiling($totalChoices / $chunkSize)
           
            #break user ID choices into chunks for making requests under max query size limit
            if ($chunkSize -lt $totalChoices) { 
                $choicesChunks = for ($i = 1; $i -le $totalChoiceChunks; $i++) {
                    $first = (($i - 1) * $chunkSize)
                    $last  = [Math]::Min(($i * $chunkSize) - 1, $totalChoices - 1)
                    ,$choices[$first..$last]
                }
            } else {
                $choicesChunks = @($choices)
            }

            $getAuditsBlock = {
                param($restUri,$authHeader,$userAuditChoiceList,$workspaceExcludeChoiceList,$lowerRangeDate,$upperRangeDate)

                [System.Collections.ArrayList]$audits = @()
                $auditQueryAPIEndpoint = "/Relativity.Rest/API/Relativity.Objects.Audits/workspaces/-1/audits/queryslim"
        
                $postBody = @{
                    "request"= @{
                        "objectType" = @{
                            "artifactTypeID" = 1000015
                        }
                        "fields"= @(
                            @{
                                "Name" = "Audit ID"
                            },
                            @{
                                "Name" = "Action"
                            },
                            @{
                                "Name" = "User Name"
                            },
                            @{
                                "Name" = "Workspace Name"
                            },
                            @{
                                "Name" = "Timestamp"
                            },
                            @{
                                "Name" = "Object Type"
                            },
                            @{
                                "Name" = "Object Name"
                            }
                        )
                        "rowCondition"="(('User Name' IN CHOICE [$userAuditChoiceList] AND 'Timestamp' >= '$lowerRangeDate`T00:00:00.00Z' AND 'Timestamp' <= '$upperRangeDate`T11:59:59.99Z' AND NOT('Workspace Name' IN CHOICE [$workspaceExcludeChoiceList])))"
                        "condition" = ""
                        "sorts" = @()
                        "relationalField" = $null
                        "searchProviderCondition" = $null
                        "includeIdWindow" = $true
                        "convertNumberFieldValuesToString" = $true
                        "isAdHocQuery" = $false
                        "activeArtifactId" = $null
                        "queryHint" = $null
                        "executingViewId" = 2
                        }
                    "start" = 1
                    "length" = 100000
                } | ConvertTo-json -Depth 5 | ForEach-Object { [System.Text.RegularExpressions.Regex]::Unescape($_) }
                
                $retryCount = 0
                $stopLoop = $false
  
                do {
                    try {
                        $queryResponse = Invoke-RestMethod $restUri$auditQueryAPIEndpoint -Headers @{ Authorization = "Basic $authHeader"; "X-CSRF-Header" = ""; "Content-Type" = "application/json;charset=UTF-8"} -Method POST -Body $postBody | Select-Object Objects
                        $auditInfo = $queryResponse.Objects | Select-Object -Property Values
                        foreach($audit in $auditInfo) {
                            $audits.Add($audit) | Out-Null
                        }
                        $stopLoop = $true  
                    }
                    catch {
                        if ($retryCount -gt 3) {
                            Write-Host "`nCould not send Information after 4 retrys."
                            Write-host "Exception: $_"
                            Write-Host "POST body: " $postBody
                            $stopLoop = $true
                        }
                        else {
                            Write-Host "`nCould not get query response retrying in 5 seconds..."
                            Write-host "Exception: $_"
                            Start-Sleep -Seconds 5
                            $retryCount = $retryCount + 1   
                        }
                    }
                } While ($stopLoop -eq $false)

                $audits
            }

            $userCounter = 0
            $totalUsersCount = $choices.Count
            $maxConcurrentJobs = 10
            $workspaceExcludeChoiceList = $workspaceChoices -join ","

            [System.Collections.ArrayList]$rawAudits = @()

            foreach($choice in $choices) {
                $percentComplete = ($userCounter / $totalUsersCount) * 100.0
                Write-Progress  -Activity "Querying $totalUsersCount Relativity Employee User Audits" -Status "$userCounter / $totalUsersCount ($percentComplete%) Complete" -PercentComplete $percentComplete
                $runningJobs = (Get-Job).Count
                $userChoiceID = $choice.ArtifactID

                if ($runningJobs -le $maxConcurrentJobs) { 
                    Start-Job -ScriptBlock $getAuditsBlock -ArgumentList $restUri,$authHeader,$userChoiceID,$workspaceExcludeChoiceList,$lowerRangeDate,$upperRangeDate -Name "Get-Audits$userChoiceID" | Out-Null
                    start-sleep -Milliseconds 500
                } else {
                    while ((Get-Job).Count -ge $maxConcurrentJobs) {
                        Get-Job | Where-Object State -NE 'Running' | ForEach-Object {
                            if ($_.State -ne 'Completed') {
                                Write-Warning ("Audit Query for User Choice ID $userChoiceID failed to recover audits.")
                            } else {
                                $jobAudits = @(Receive-Job $_)
                                foreach($audit in $jobAudits) {
                                    $rawAudits.Add($audit) | Out-Null
                                }
                            }
                            remove-job $_
                        }
                        start-sleep -Milliseconds 500
                    }
                   
                    Start-Job -ScriptBlock $getAuditsBlock -ArgumentList $restUri,$authHeader,$userChoiceID,$workspaceExcludeChoiceList,$lowerRangeDate,$upperRangeDate -Name "Get-Audits$userChoiceID" | Out-Null
                    start-sleep -Milliseconds 500
                }
                $userCounter++
            }

            #wait for remaining jobs to complete
            while (Get-Job) {
                Get-Job | Where-Object State -NE 'Running' | ForEach-Object {
                    if ($_.State -ne 'Completed') {
                        Write-Warning ('Job [{0}] [{1}] ended with state [{2}].' -f $_.id,$_.Name,$_.State)
                    } else {
                        $jobAudits = @(Receive-Job $_)
                        foreach($audit in $jobAudits) {
                            $rawAudits.Add($audit) | Out-Null
                        }
                    }
                    remove-job $_
                }
                start-sleep -Milliseconds 500
            }

            Write-Progress -Activity "Querying Relativity Employee User Audits" -Status "Complete" -Completed
            Write-Host "Processing Results"

            $parsedAudits = @()

            $auditCounter = 0
            foreach ($audit in $rawAudits)
            {
                $percentComplete = ($auditCounter / $rawAudits.Count) * 100.0
                Write-Progress  -Activity "Processing Audit Results" -Status "$percentComplete% Complete" -PercentComplete $percentComplete
                $parsedAudits += @{
                    "Audit ID" = $audit.Values[0]
                    "Workspace Name" = $audit.Values[3].Name
                    "User Name" = $audit.Values[2].Name
                    "Action" = $audit.Values[1].Name
                    "Timestamp" = $audit.Values[4]
                    "Object Type" = $audit.Values[5].Name
                    "Object Name" = $audit.Values[6]
                }
                $auditCounter++
            }

            Write-Progress -Activity "Processing Audit Results" -Status "Complete" -Completed
            Write-Host "Retrieved " $parsedAudits.Count " Total Audits"
            Write-Host "Formatting results"

            $csvFormattedResults = "";

            if ($groupByWorkspace.IsPresent) {
                $_groupingField = "Workspace Name"
                Write-Host "Grouping Audit data by $_groupingField"
                $_allAudits = Group-ByAuditField $parsedAudits $_groupingField
                $csvFormattedResults = Get-GroupedCsvData $_allAudits $_groupingField
            }
            elseif ($groupByUser.IsPresent) {  
                $_groupingField = "User Name"
                Write-Host "Grouping Audit data by $_groupingField"
                $_allAudits = Group-ByAuditField $parsedAudits $_groupingField
                $csvFormattedResults = Get-GroupedCsvData $_allAudits $_groupingField
            }
            elseif ($groupByAction.IsPresent) {
                $_groupingField = "Action"
                Write-Host "Grouping Audit data by $_groupingField"
                $_allAudits = Group-ByAuditField $parsedAudits $_groupingField
                $csvFormattedResults = Get-GroupedCsvData $_allAudits $_groupingField
            }
            else {
                $csvFormattedResults = Get-CsvData $parsedAudits
            }

            $parsedAudits = @()
            $rawAudits = @()
            $_allAudits = @()
            $retryCount = 0
            $stopLoop = $false
            $jobAudits = @()
            $choices = @()
            $choicesChunks = @()
            $workspaceChoices = @()

            Write-Host "Formatting Complete. Exiting script."
            return $csvFormattedResults
}

function Group-ByAuditField($allAudits, $groupingField){
    $auditDictionary = @{}

    foreach($audit in $allAudits) {
        if ($auditDictionary.Contains($audit["$groupingField"])) {
            $auditsList = $auditDictionary[$audit["$groupingField"]]
            $auditsList.Add($audit) | Out-Null
        }
        else {
            [System.Collections.ArrayList]$auditsList = @()
            $auditsList.Add($audit) | Out-Null
            $auditDictionary.Add($audit["$groupingField"], $auditsList) | Out-Null
        }
    }

    return $auditDictionary
}

function Get-GroupedCsvData($groupedAudits, $groupingField) {
    $output = "";
    foreach($groupKey in $groupedAudits.Keys){
        $output += "Relativity Employee Audit Events for $groupingField '$groupKey'`n"
        $output += $_headers
        $groupAuditEvents = $groupedAudits["$groupKey"]

        foreach ($auditEvent in $groupAuditEvents) {
            try {
                $auditID = if ($null -eq $auditEvent["Audit ID"]) {""} else {$auditEvent["Audit ID"]}   
                $timestamp = if ($null -eq $auditEvent["Timestamp"]) {""} else {$auditEvent["Timestamp"]}   
                $workspaceName = if ($null -eq  $auditEvent["Workspace Name"]) {""} else { $auditEvent["Workspace Name"].Replace(",","")} 
                $userName =  if ($null -eq $auditEvent["User Name"]) {""} else {$auditEvent["User Name"].Replace(",","")}   
                $auditAction = if ($null -eq $auditEvent["Action"]) {""} else {$auditEvent["Action"]}  
                $objectType = if ($null -eq $auditEvent["Object Type"]) {""} else {$auditEvent["Object Type"]}  
                $objectName = if ($null -eq $auditEvent["Object Name"]) {""} else {$auditEvent["Object Name"].Replace(",","")}
                $eventCsv = $auditID,$timestamp,$workspaceName,$userName,$auditAction,$objectType,$objectName -Join ","
                $output += "$eventCsv`n"
            } catch {
                $auditJsonData = $auditEvent | ConvertTo-Json
                Write-Host "Error adding audit to grouped csv data: " $_ " Unable to append audit: " $auditJsonData
            }  
        }
        $output += "`n"
    }

    return $output
}

function Get-CsvData($audits) {
    $output = "";
    $output += "All Relativity Employee Audit Events`n"
    $output += $_headers
    
    foreach ($auditEvent in $audits) {
        try {
            $auditID = if ($null -eq $auditEvent["Audit ID"]) {""} else {$auditEvent["Audit ID"]}   
            $timestamp = if ($null -eq $auditEvent["Timestamp"]) {""} else {$auditEvent["Timestamp"]}   
            $workspaceName = if ($null -eq  $auditEvent["Workspace Name"]) {""} else { $auditEvent["Workspace Name"].Replace(",","")} 
            $userName =  if ($null -eq $auditEvent["User Name"]) {""} else {$auditEvent["User Name"].Replace(",","")}   
            $auditAction = if ($null -eq $auditEvent["Action"]) {""} else {$auditEvent["Action"]}  
            $objectType = if ($null -eq $auditEvent["Object Type"]) {""} else {$auditEvent["Object Type"]}  
            $objectName = if ($null -eq $auditEvent["Object Name"]) {""} else {$auditEvent["Object Name"].Replace(",","")}
            $eventCsv = $auditID,$timestamp,$workspaceName,$userName,$auditAction,$objectType,$objectName -Join ","
            $output += "$eventCsv`n"
        } catch {
            $auditJsonData = $auditEvent | ConvertTo-Json
            Write-Host "Error adding audit to grouped csv data: " $_ " Unable to append audit: " $auditJsonData
        }  
    }
    $output += "`n"
    
    return $output
}

$_groupingField = ""
$_allAudits = @()
$_headers = "AuditID","Timestamp(UTC)","WorkspaceName","UserName","Action","ObjectType","ObjectName`n" -Join "," 