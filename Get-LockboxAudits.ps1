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
    (Optional) Include this flag to show audits that took place in the Admin Case configuration workspace. This will show audits for system configuration changes such as Login events, User and Group object changes, and Instance Setting edits.

NOTES:
    - The restUserName and restPassword need to be for an account which has both Audit API access, such as System Administrator group members, and a Password Login Method.
    - To capture all events up to the script run time, it is recommended that the upperRangeDate parameter be set to tomorrow's date.
    - Disclaimer for RelativityOne environment usage:
        - This script is limited to public Audit APIs for retrieving audit events.
        - Due to technical limitations of the public Audit APIs and the automatic deletion of Relativity Employee accounts, audits of deleted Relativity Employees are only available via this script for as long as the employee accounts exist in the Relativity environment.
        - It is recommended that the script be run at least daily to capture Relativity Employee audits before the user accounts are removed. The script can be run as often as desired to ensure all Relativity Employee access is captured.

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
    Output Audits to Console, grouped by Workspace: 
    > Get-Audits-For-Users-In-Workspace -restUri $restUri -restUserName $restUserName -restPassword $SecureStringPassword -lowerRangeDate $lowerRangeDate -upperRangeDate $upperRangeDate -groupByWorkspace
    Group audits by User Name, including audits for the Admin Case, and Save Audits to a .csv file:
    > Get-Audits-For-Users-In-Workspace -restUri $restUri -restUserName $restUserName -restPassword $SecureStringPassword -lowerRangeDate $lowerRangeDate -upperRangeDate $upperRangeDate -groupByUser| Out-File -FilePath .\Audits.csv
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
                        Write-Host $usernameBody
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

            Write-Host "Generating audit query from users"

            $choiceAPIEndpoint = "/Relativity.Rest/api/Relativity.Services.ChoiceQuery.IChoiceQueryModule/Choice Query Manager/QueryAsync"
            $choiceNameList =  ($userNames | Select-Object @{name="Clause";expression= {"'Name' == '$($_.FullName)'"}}).Clause -join " OR "
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

            $choices = @()
            do {
                try {
                    $queryResponse = Invoke-RestMethod $restUri$choiceAPIEndpoint -Headers @{ Authorization = "Basic $authHeader"; "X-CSRF-Header" = ""; "Content-Type" = "application/json;charset=UTF-8"} -Method POST -Body $choiceBody 
                    $choices = $queryResponse.Objects | Select-Object -Property ArtifactID
                    $stopLoop = $true  
                }
                catch {
                    if ($retryCount -gt 3){
                        Write-Host "Could not send Information after 4 retrys."
                        Write-Host $usernameBody
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

            Write-Host "Querying for workspaces to exclude"

            if ($getAdminCaseAudits.IsPresent) {
                $workspaceExcludeNames = @("[DO NOT ACCESS] - RelativityOne Automation", "[DO NOT ACCESS] - RelativityOne Maintenance", "[DO NOT ACCESS] - RelativityOne Template",	"New Case Template", "Relativity Starter Template")
            }
            else {
                $workspaceExcludeNames = @("[DO NOT ACCESS] - RelativityOne Automation", "[DO NOT ACCESS] - RelativityOne Maintenance", "[DO NOT ACCESS] - RelativityOne Template",	"New Case Template", "Relativity Starter Template", "Admin Case") 
            }
            
            $workspaceExcludeString = ($workspaceExcludeNames | Select-Object  @{name="Clause";expression= {"'Name' <> '$_'"}}).Clause -join " AND "
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

            $workspaces = @()
            do {
                try {
                    $queryResponse = Invoke-RestMethod $restUri$choiceAPIEndpoint -Headers @{ Authorization = "Basic $authHeader"; "X-CSRF-Header" = ""; "Content-Type" = "application/json;charset=UTF-8"} -Method POST -Body $workspaceBody 
                    $workspaces = $queryResponse.Objects.ArtifactID 
                    $stopLoop = $true  
                }
                catch {
                    if ($retryCount -gt 3){
                        Write-Host "Could not send Information after 4 retrys."
                        Write-Host $usernameBody
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

            $userAuditChoiceList = $choices.ArtifactID -join ","
            $workspaceExcludeChoiceList = $workspaces -join ","
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
                    "rowCondition"="(('User Name' IN CHOICE [$userAuditChoiceList] AND 'Timestamp' >= '$lowerRangeDate`T00:00:00.00Z' AND 'Timestamp' <= '$upperRangeDate`T11:59:59.00Z' AND 'Workspace Name' IN CHOICE [$workspaceExcludeChoiceList]))"
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
            
            $auditInfo = @{}
            do {
                try {
                    $queryResponse = Invoke-RestMethod $restUri$auditQueryAPIEndpoint -Headers @{ Authorization = "Basic $authHeader"; "X-CSRF-Header" = ""; "Content-Type" = "application/json;charset=UTF-8"} -Method POST -Body $postBody | Select-Object Objects
                    $auditInfo = $queryResponse.Objects | Select-Object -Property Values
                    $stopLoop = $true  
                }
                catch {
                    if ($retryCount -gt 3){
                        Write-Host "Could not send Information after 4 retrys."
                        Write-Host $postBody
                        $stopLoop = $true
                    }
                    else {
                        Write-Host "Could not get response retrying in 30 seconds..."
                        Start-Sleep -Seconds 30
                        $retryCount = $retryCount + 1
                    }
                }
            } While ($stopLoop -eq $false)

            $parsedAudits = @()

            foreach ($audit in $auditInfo)
            {
                $parsedAudits += @{
                    "Audit ID" = $audit.Values[0]
                    "Workspace Name" = $audit.Values[3].Name
                    "User Name" = $audit.Values[2].Name
                    "Action" = $audit.Values[1].Name
                    "Timestamp" = $audit.Values[4]
                    "Object Type" = $audit.Values[5].Name
                    "Object Name" = $audit.Values[6]
                }
            }

            Write-Host "Formatting results"

            $csvFormattedResults = "";

            if ($groupByWorkspace.IsPresent) {
                $_groupingField = "Workspace Name"
                Write-Host "Grouping audit data by $_groupingField"
                $_allAudits = Group-ByAuditField $parsedAudits $_groupingField
                $csvFormattedResults = Get-GroupedCsvData $_allAudits $_groupingField
            }
            elseif ($groupByUser.IsPresent) {  
                $_groupingField = "User Name"
                Write-Host "Grouping audit data by $_groupingField"
                $_allAudits = Group-ByAuditField $parsedAudits $_groupingField
                $csvFormattedResults = Get-GroupedCsvData $_allAudits $_groupingField
            }
            elseif ($groupByAction.IsPresent) {
                $_groupingField = "Action"
                Write-Host "Grouping audit data by $_groupingField"
                $_allAudits = Group-ByAuditField $parsedAudits $_groupingField
                $csvFormattedResults = Get-GroupedCsvData $_allAudits $_groupingField
            }
            else {
                $csvFormattedResults = Get-CsvData $parsedAudits
            }

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
            $eventCsv = $auditEvent["Audit ID"],$auditEvent["Timestamp"],$auditEvent["Workspace Name"].Replace(",",""),$auditEvent["User Name"].Replace(",",""),$auditEvent["Action"],$auditEvent["Object Type"],$auditEvent["Object Name"].Replace(",","") -Join ","
            $output += "$eventCsv`n"
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
        $eventCsv = $auditEvent["Audit ID"],$auditEvent["Timestamp"],$auditEvent["Workspace Name"].Replace(",",""),$auditEvent["User Name"].Replace(",",""),$auditEvent["Action"],$auditEvent["Object Type"],$auditEvent["Object Name"].Replace(",","") -Join ","
        $output += "$eventCsv`n"
    }
    $output += "`n"
    
    return $output
}

$_groupingField = ""
$_allAudits = @()
$_headers = "AuditID","Timestamp(UTC)","WorkspaceName","UserName","Action","ObjectType", "ObjectName`n" -Join "," 