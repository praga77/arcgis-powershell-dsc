function Get-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Collections.Hashtable])]
	param
	(
        [parameter(Mandatory = $true)]
        [System.String]
        $PortalHostName,

        [parameter(Mandatory = $true)]
		[System.String]
		$PortalAdministrator
	)
	
    Import-Module $PSScriptRoot\..\..\ArcGISUtility.psm1 -Verbose:$false

    $null
}

function Set-TargetResource
{
	[CmdletBinding()]
	param
	(
        [parameter(Mandatory = $true)]
        [System.String]
        $PortalHostName,

        [parameter(Mandatory = $true)]
		[System.Management.Automation.PSCredential]
		$PortalAdministrator
	)
    
    Import-Module $PSScriptRoot\..\..\ArcGISUtility.psm1 -Verbose:$false

    $FQDN = Get-FQDN $PortalHostName
    $Referer = "https://localhost"

    [string]$UpgradeUrl = "https://$($FQDN):7443/arcgis/portaladmin/upgrade"
    $UpgradeResponse = Invoke-ArcGISWebRequest -Url $UpgradeUrl -HttpFormParameters @{f = 'json'; isBackupRequired = $true; isRollbackRequired = $true} -Referer $Referer -TimeOutSec 86400 -LogResponse 
    $ResponseJSON = ConvertTo-Json $UpgradeResponse -Compress -Depth 5
    Write-Verbose "Response received from Upgrade site $ResponseJSON"  
    if($UpgradeResponse.error) {
        Write-Verbose
        throw  "[ERROR]:- $ResponseJSON"
    }
    if($Response.status -ieq 'success') {
        Write-Verbose "Upgrade Successful"
        if($UpgradeResponse.recheckAfterSeconds -ne $null) 
        {
            Write-Verbose "Sleeping for $($UpgradeResponse.recheckAfterSeconds*2) seconds"
            Start-Sleep -Seconds ($UpgradeResponse.recheckAfterSeconds*2)
        }
    }  
    
    Wait-ForPortalToStart -PortalHttpsUrl "https://$($FQDN):7443" -PortalSiteName "arcgis" -PortalAdminCredential $PortalAdministrator -Referer $Referer

    $token = Get-PortalToken -PortalHostName $FQDN -SiteName 'arcgis' -Credential $PortalAdministrator -Referer $Referer
    if(-not($token.token)) {
        throw "Unable to retrieve Portal Token for '$PortalAdminUserName'"
    }
    Write-Verbose "Connected to Portal successfully and retrieved token for '$($PortalAdministrator.UserName)'"

    Write-Verbose "Post Upgrade Step"
    [string]$postUpgradeUrl = "https://$($FQDN):7443/arcgis/portaladmin/postUpgrade"
    $postUpgradeResponse = Invoke-ArcGISWebRequest -Url $postUpgradeUrl -HttpFormParameters @{f = 'json'; token = $token.token} -Referer $Referer -TimeOutSec 3000 -LogResponse 
    $ResponseJSON = ConvertTo-Json $postUpgradeResponse -Compress -Depth 5
    Write-Verbose "Response received from Upgrade site $postUpgradeResponse"  
    if($postUpgradeResponse.status -ieq "success"){
        Write-Verbose "Post Upgrade Step Successful"
    }

    Write-Verbose "Reindexing Portal"
    Upgrade-Reindex -PortalHttpsUrl "https://$($FQDN):7443" -PortalSiteName 'arcgis' -Referer $Referer -Token $token.token
}

function Test-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Boolean])]
	param
	(
        [parameter(Mandatory = $true)]
        [System.String]
        $PortalHostName,
        
        [parameter(Mandatory = $true)]
		[System.Management.Automation.PSCredential]
		$PortalAdministrator
	)
    [System.Reflection.Assembly]::LoadWithPartialName("System.Web") | Out-Null
    Import-Module $PSScriptRoot\..\..\ArcGISUtility.psm1 -Verbose:$false

    $FQDN = Get-FQDN $PortalHostName
    $Referer = "https://localhost"
    
    Wait-ForUrl -Url "https://$($FQDN):7443/arcgis/portaladmin" -MaxWaitTimeInSeconds 600 -SleepTimeInSeconds 15 -HttpMethod 'GET'

    $TestPortalResponse = Invoke-ArcGISWebRequest -Url "https://$($FQDN):7443/arcgis/portaladmin" -HttpFormParameters @{ f = 'json' } -Referer $Referer -LogResponse -HttpMethod 'GET'
    if($TestPortalResponse.status -ieq "error" -and $TestPortalResponse.isUpgrade -ieq $true -and $TestPortalResponse.messages[0] -ieq "The portal site has not been upgraded. Please upgrade the site and try again."){
        $false
    }else{
        $PortalHealthCheck = Invoke-ArcGISWebRequest -Url "https://$($FQDN):7443/arcgis/portaladmin/healthCheck" -HttpFormParameters @{ f = 'json' } -Referer $Referer -LogResponse -HttpMethod 'GET'
        if($PortalHealthCheck.status -ieq "success"){
            $true
        }else{
            $jsresponse = ConvertTo-Json $TestPortalResponse -Compress -Depth 5
            Write-Verbose "[WARNING]:- $jsresponse "
        }
    }
}
function Upgrade-Reindex(){

    [CmdletBinding()]
    param(
        [System.String]
        $PortalHttpsUrl, 
        
        [System.String]
		$PortalSiteName = 'arcgis', 

        [System.String]
		$Token, 

        [System.String]
		$Referer = 'http://localhost'
        
    )

    [string]$ReindexSiteUrl = $PortalHttpsUrl.TrimEnd('/') + "/$PortalSiteName/portaladmin/system/indexer/reindex"

    $WebParams = @{ 
                    mode = 'FULL_MODE'
                    f = 'json'
                    token = $Token
                  }

    Write-Verbose "Making request to $ReindexSiteUrl to create the site"
    $Response = Invoke-ArcGISWebRequest -Url $ReindexSiteUrl -HttpFormParameters $WebParams -Referer $Referer -TimeOutSec 3000 -LogResponse 
    Write-Verbose "Response received from Reindex site $Response "  
    if($Response.error -and $Response.error.message) {
        throw $Response.error.message
    }
    if($Response.status -ieq 'success') {
        Write-Verbose "Reindexing Successful"
    }
}
function Wait-ForPortalToStart
{
    [CmdletBinding()]
    param(
        [string]$PortalHttpsUrl, 
        [string]$PortalSiteName, 
        [System.Management.Automation.PSCredential]$PortalAdminCredential, 
        [string]$Referer,
        [int]$MaxAttempts = 40,
        [int]$SleepTimeInSeconds = 15
    )

    ##
    ## Wait for the Portal Admin to start back up
    ##
    [string]$CheckPortalAdminUrl = $PortalHttpsUrl.TrimEnd('/') + "/$PortalSiteName/sharing/rest/generateToken"  
    $WebParams = @{ username = $PortalAdminCredential.UserName 
                    password = $PortalAdminCredential.GetNetworkCredential().Password                 
                    client = 'requestip'
                    f = 'json'
                  }
    $HttpBody = To-HttpBody $WebParams
    [bool]$Done = $false
    [int]$NumOfAttempts = 0
    Write-Verbose "Check sharing API Url:- $CheckPortalAdminUrl"
    $Headers = @{'Content-type'='application/x-www-form-urlencoded'
                  'Content-Length' = $HttpBody.Length
                  'Accept' = 'text/plain'     
                  'Referer' = $Referer             
                }
    while(($Done -eq $false) -and ($NumOfAttempts -lt $MaxAttempts))
    {
        if($NumOfAttempts -gt 1) {
            Write-Verbose "Attempt # $NumOfAttempts"            
        }
        
        $response = $null
        Try {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
            $response = Invoke-RestMethod -Method Post -Uri $CheckPortalAdminUrl -Headers $Headers -Body $HttpBody -TimeoutSec 30 # -MaximumRedirection 1
            if(($response -ne $null) -and ($response.token -ne $null) -and ($response.token.Length -gt 0))        {    
                Write-Verbose "Portal returned a token successfully"  
                $Done = $true                
            }elseif($response -ne $null){
                Write-Verbose (ConvertTo-Json $response -Compress -Depth 5)
                if($NumOfAttempts -gt 1) {
                    Write-Verbose "Sleeping for $SleepTimeInSeconds seconds"
                }
                Start-Sleep -Seconds $SleepTimeInSeconds
                $NumOfAttempts++
            }
        }catch{
            Write-Verbose "[WARNING]:- Exception:- $($_)"     
        }
    }
}

Export-ModuleMember -Function *-TargetResource