
function RefreshTokens()
{
    #Copy external blob content
    $global:powerbitoken = ((az account get-access-token --resource https://analysis.windows.net/powerbi/api) | ConvertFrom-Json).accessToken
    $global:synapseToken = ((az account get-access-token --resource https://dev.azuresynapse.net) | ConvertFrom-Json).accessToken
    $global:graphToken = ((az account get-access-token --resource https://graph.microsoft.com) | ConvertFrom-Json).accessToken
    $global:managementToken = ((az account get-access-token --resource https://management.azure.com) | ConvertFrom-Json).accessToken
}

function ReplaceTokensInFile($ht, $filePath)
{
    $template = Get-Content -Raw -Path $filePath
	
    foreach ($paramName in $ht.Keys) 
    {
		$template = $template.Replace($paramName, $ht[$paramName])
	}

    return $template;
}


#should auto for this.
az login

#for powershell...
Connect-AzAccount -DeviceCode

#will be done as part of the cloud shell start - README

#if they have many subs...
$subs = Get-AzSubscription | Select-Object -ExpandProperty Name

if($subs.GetType().IsArray -and $subs.length -gt 1)
{
    $subOptions = [System.Collections.ArrayList]::new()
    for($subIdx=0; $subIdx -lt $subs.length; $subIdx++)
    {
        $opt = New-Object System.Management.Automation.Host.ChoiceDescription "$($subs[$subIdx])", "Selects the $($subs[$subIdx]) subscription."   
        $subOptions.Add($opt)
    }
    $selectedSubIdx = $host.ui.PromptForChoice('Enter the desired Azure Subscription for this lab','Copy and paste the name of the subscription to make your choice.', $subOptions.ToArray(),0)
    $selectedSubName = $subs[$selectedSubIdx]
    Write-Host "Selecting the $selectedSubName subscription"
    Select-AzSubscription -SubscriptionName $selectedSubName
    az account set --subscription $selectedSubName
}

#Getting User Inputs
$rgName = read-host "Enter the resource Group Name";
$location = (Get-AzResourceGroup -Name $rgName).Location
$init =  (Get-AzResourceGroup -Name $rgName).Tags["DeploymentId"]
$random =  (Get-AzResourceGroup -Name $rgName).Tags["UniqueId"]
$suffix = "$random-$init"
$wsId =  (Get-AzResourceGroup -Name $rgName).Tags["WsId"]        
$deploymentId = $init
$concatString = "$init$random"
$dataLakeAccountName = "stfintax$concatString"
if($dataLakeAccountName.length -gt 24)
{
$dataLakeAccountName = $dataLakeAccountName.substring(0,24)
}

$bot_qnamaker_fintax_name= "botmultilingual-$suffix";
$app_immersive_reader_fintax_name = "immersive-reader-fintax-app-$suffix";
$app_fintaxdemo_name = "fintaxdemo-app-$suffix";
$subscriptionId = (Get-AzContext).Subscription.Id
$tenantId = (Get-AzContext).Tenant.Id
$CurrentTime = Get-Date
$AADAppClientSecretExpiration = $CurrentTime.AddDays(365)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
#refresh environment variables
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

#Web app
Write-Host  "-----------------Deploy web app ---------------"
RefreshTokens

expand-archive -path "../artifacts/binaries/fintaxdemo-app.zip" -destinationpath "./fintaxdemo-app" -force

$spname="FinTax Demo $deploymentId"

$app = az ad app create --display-name $spname | ConvertFrom-Json
$appId = $app.appId

$mainAppCredential = az ad app credential reset --id $appId | ConvertFrom-Json
$clientsecpwd = $mainAppCredential.password

az ad sp create --id $appId | Out-Null    
$sp = az ad sp show --id $appId --query "id" -o tsv
start-sleep -s 60

#https://docs.microsoft.com/en-us/power-bi/developer/embedded/embed-service-principal
#Allow service principals to user PowerBI APIS must be enabled - https://app.powerbi.com/admin-portal/tenantSettings?language=en-U
#add PowerBI App to workspace as an admin to group
RefreshTokens
$url = "https://api.powerbi.com/v1.0/myorg/groups";
$result = Invoke-WebRequest -Uri $url -Method GET -ContentType "application/json" -Headers @{ Authorization="Bearer $powerbitoken" } -ea SilentlyContinue;
$homeCluster = $result.Headers["home-cluster-uri"]
#$homeCluser = "https://wabi-west-us-redirect.analysis.windows.net";

RefreshTokens
$url = "$homeCluster/metadata/tenantsettings"
$post = "{`"featureSwitches`":[{`"switchId`":306,`"switchName`":`"ServicePrincipalAccess`",`"isEnabled`":true,`"isGranular`":true,`"allowedSecurityGroups`":[],`"deniedSecurityGroups`":[]}],`"properties`":[{`"tenantSettingName`":`"ServicePrincipalAccess`",`"properties`":{`"HideServicePrincipalsNotification`":`"false`"}}]}"
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Authorization", "Bearer $powerbiToken")
$headers.Add("X-PowerBI-User-Admin", "true")
#$result = Invoke-RestMethod -Uri $url -Method PUT -body $post -ContentType "application/json" -Headers $headers -ea SilentlyContinue;

#add PowerBI App to workspace as an admin to group
RefreshTokens
$url = "https://api.powerbi.com/v1.0/myorg/groups/$wsid/users";
$post = "{
    `"identifier`":`"$($sp)`",
    `"groupUserAccessRight`":`"Admin`",
    `"principalType`":`"App`"
    }";

$result = Invoke-RestMethod -Uri $url -Method POST -body $post -ContentType "application/json" -Headers @{ Authorization="Bearer $powerbitoken" } -ea SilentlyContinue;

#get the power bi app...
$powerBIApp = Get-AzADServicePrincipal -DisplayNameBeginsWith "Power BI Service"
$powerBiAppId = $powerBIApp.Id;

#setup powerBI app...
RefreshTokens
$url = "https://graph.microsoft.com/beta/OAuth2PermissionGrants";
$post = "{
    `"clientId`":`"$appId`",
    `"consentType`":`"AllPrincipals`",
    `"resourceId`":`"$powerBiAppId`",
    `"scope`":`"Dataset.ReadWrite.All Dashboard.Read.All Report.Read.All Group.Read Group.Read.All Content.Create Metadata.View_Any Dataset.Read.All Data.Alter_Any`",
    `"expiryTime`":`"2021-03-29T14:35:32.4943409+03:00`",
    `"startTime`":`"2020-03-29T14:35:32.4933413+03:00`"
    }";

$result = Invoke-RestMethod -Uri $url -Method GET -ContentType "application/json" -Headers @{ Authorization="Bearer $graphtoken" } -ea SilentlyContinue;

#setup powerBI app...
RefreshTokens
$url = "https://graph.microsoft.com/beta/OAuth2PermissionGrants";
$post = "{
    `"clientId`":`"$appId`",
    `"consentType`":`"AllPrincipals`",
    `"resourceId`":`"$powerBiAppId`",
    `"scope`":`"User.Read Directory.AccessAsUser.All`",
    `"expiryTime`":`"2021-03-29T14:35:32.4943409+03:00`",
    `"startTime`":`"2020-03-29T14:35:32.4933413+03:00`"
    }";

$result = Invoke-RestMethod -Uri $url -Method GET -ContentType "application/json" -Headers @{ Authorization="Bearer $graphtoken" } -ea SilentlyContinue;
				
(Get-Content -path fintaxdemo-app/appsettings.json -Raw) | Foreach-Object { $_ `
                -replace '#WORKSPACE_ID#', $wsId`
				-replace '#APP_ID#', $appId`
				-replace '#APP_SECRET#', $clientsecpwd`
				-replace '#TENANT_ID#', $tenantId`				
        } | Set-Content -Path fintaxdemo-app/appsettings.json

$filepath="./fintaxdemo-app/wwwroot/config.js"
$itemTemplate = Get-Content -Path $filepath
$item = $itemTemplate.Replace("#STORAGE_ACCOUNT#", $dataLakeAccountName).Replace("#SERVER_NAME#", $app_fintaxdemo_name).Replace("#APP_NAME#", $app_fintaxdemo_name)
Set-Content -Path $filepath -Value $item 

#bot qna maker
$bot_detail = az bot webchat show --name $bot_qnamaker_fintax_name --resource-group $rgName --with-secrets true | ConvertFrom-Json
$bot_key = $bot_detail.properties.properties.sites[0].key

RefreshTokens
$url = "https://api.powerbi.com/v1.0/myorg/groups/$wsId/reports";
$reportList = Invoke-RestMethod -Uri $url -Method GET -Headers @{ Authorization="Bearer $powerbitoken" };
$reportList = $reportList.Value

#update all th report ids in the poc web app...
$ht = new-object system.collections.hashtable   
#TODO need to check which url to use here
# $ht.add("#Blob_Base_Url#", "https://fsicdn.azureedge.net/webappassets/")
$ht.add("#Bing_Map_Key#", "AhBNZSn-fKVSNUE5xYFbW_qajVAZwWYc8OoSHlH8nmchGuDI6ykzYjrtbwuNSrR8")
$ht.add("#IMMERSIVE_READER_FINTAX_NAME#", $app_immersive_reader_fintax_name)
$ht.add("#BOT_QNAMAKER_FINTAX_NAME#", $bot_qnamaker_fintax_name)
$ht.add("#BOT_KEY#", $bot_key)
$ht.add("#AMAZON_MAP#", $($reportList | where {$_.name -eq "Amazon MAP"}).id)
$ht.add("#ANTI_CORRUPTION_REPORT#", $($reportList | where {$_.name -eq "Anti Corruption Report"}).id)
#.add("#FINTAX_COLUMN_LEVEL_SECURITY_SYNAPSE#", $($reportList | where {$_.name -eq "FinTax Column Level Security (Azure Synapse)"}).id)
#$ht.add("#FINTAX_DYNAMIC_DATA_MASKING_SYNAPSE#", $($reportList | where {$_.name -eq "FinTax Dynamic Data Masking (Azure Synapse)"}).id)
#$ht.add("#FINTAX_ROW_LEVEL_SECURITY_SYNAPSE#", $($reportList | where {$_.name -eq "FinTax Row Level Security (Azure Synapse)"}).id)
$ht.add("#FRAUD_INVESTIGATOR_REPORT#", $($reportList | where {$_.name -eq "Fraud Investigator Report"}).id)
$ht.add("#REPORT_TAX_FINANCE#", $($reportList | where {$_.name -eq "Report Tax Finance"}).id)
#$ht.add("#TAX_COLLECTIONS_COMMISSIONER#", $($reportList | where {$_.name -eq "Tax Collections Commissioner"}).id)
$ht.add("#TAX_COMPLIANCE_COMISSIONER_REPORT#", $($reportList | where {$_.name -eq "Tax Compliance Comissioner Report"}).id)
#$ht.add("#TAXPAYER_CLIENT_SERVICES_REPORT#", $($reportList | where {$_.name -eq "Taxpayer Client Services Report"}).id)
#$ht.add("#TRF_CHICKLETS#", $($reportList | where {$_.name -eq "TRF-Chicklets"}).id)
$ht.add("#VAT_AUDITOR_REPORT#", $($reportList | where {$_.name -eq "vat auditor report"}).id)

#$ht.add("#SPEECH_REGION#", $location)

$filePath = "./fintaxdemo-app/wwwroot/config.js";
Set-Content $filePath $(ReplaceTokensInFile $ht $filePath)

Compress-Archive -Path "./fintaxdemo-app/*" -DestinationPath "./fintaxdemo-app.zip" -Force

az webapp stop --name $app_fintaxdemo_name --resource-group $rgName

try{
az webapp deployment source config-zip --resource-group $rgName --name $app_fintaxdemo_name --src "./fintaxdemo-app.zip"
}
catch
{
}

az webapp start --name $app_fintaxdemo_name --resource-group $rgName

