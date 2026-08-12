#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources, Az.Storage

<#
.SYNOPSIS
    Bootstraps the Azure landing zone prerequisites that Terraform cannot create for itself.

.DESCRIPTION
    Run this once, from your workstation, before anything else. It creates:

      1. A storage account to hold Terraform remote state, with versioning and
         soft delete enabled and shared key access disabled.
      2. An Entra app registration with federated credentials so GitHub Actions
         can authenticate to Azure with no stored secret.
      3. The role assignments both of the above require.

    After this runs, nothing should touch Azure except the pipeline.

    The script is idempotent. Re-running it against an existing bootstrap will
    detect and reuse what is already there rather than failing or duplicating.

.PARAMETER OrgCode
    Short prefix applied to every resource name. Lowercase alphanumeric.

.PARAMETER GitHubOrg
    Your GitHub username or organization name.

.PARAMETER GitHubRepo
    Repository name. Must match exactly, the federated credential subject is
    a literal string match and a typo produces an auth failure that is
    genuinely unpleasant to diagnose.

.PARAMETER SubscriptionId
    Target subscription. Defaults to the current context.

.EXAMPLE
    ./Initialize-AzureBootstrap.ps1 -GitHubOrg 'joshuaolliff' -GitHubRepo 'azure-landing-zone'

.EXAMPLE
    ./Initialize-AzureBootstrap.ps1 -GitHubOrg 'joshuaolliff' -GitHubRepo 'azure-landing-zone' -WhatIf

.NOTES
    Requires Owner on the target subscription.
    Az.Resources 6.0 or later for New-AzADAppFederatedCredential.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[a-z0-9]{2,6}$')]
    [string]$OrgCode = 'jbo',

    [Parameter(Mandatory)]
    [string]$GitHubOrg,

    [string]$GitHubRepo = 'azure-landing-zone',

    [string]$Location = 'eastus2',

    [string]$LocationShort = 'eus2',

    [string]$SubscriptionId,

    [ValidateSet('Owner', 'Contributor')]
    [string]$PipelineRole = 'Owner',

    [switch]$IncludeManagementGroupScope
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Helpers -------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host ">> $Message" -ForegroundColor Cyan
}

function Write-Detail {
    param([string]$Message)
    Write-Host "   $Message" -ForegroundColor DarkGray
}

function Wait-ForRolePropagation {
    <#
        Entra role assignments are eventually consistent. Creating a container
        immediately after granting yourself the data plane role fails often
        enough that a retry loop is worth more than a fixed sleep.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Test,
        [int]$TimeoutSeconds = 180,
        [int]$IntervalSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            if (& $Test) { return $true }
        }
        catch {
            Write-Detail "waiting on propagation: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $IntervalSeconds
    } while ((Get-Date) -lt $deadline)

    throw "Role assignment did not propagate within $TimeoutSeconds seconds."
}

#endregion

#region Preflight -----------------------------------------------------------

Write-Step 'Checking Azure context'

$context = Get-AzContext
if (-not $context) {
    throw 'Not connected. Run Connect-AzAccount first.'
}

if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
    Write-Detail "Switching context to $SubscriptionId"
    $context = Set-AzContext -SubscriptionId $SubscriptionId
}

$subId    = $context.Subscription.Id
$tenantId = $context.Tenant.Id

# Get-AzADUser -SignedIn is cleaner but is not present in every Az.Resources
# version, so fall back to a UPN lookup.
$currentUser = try {
    Get-AzADUser -SignedIn
}
catch {
    Get-AzADUser -UserPrincipalName $context.Account.Id
}

if (-not $currentUser) {
    throw 'Could not resolve the signed-in user object. Service principal logins are not supported for bootstrap.'
}

# Storage account names are globally unique and allow no hyphens or uppercase.
$randomSuffix = -join ((48..57) + (97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ })

$stateRg        = "$OrgCode-tfstate-$LocationShort-rg"
$stateSa        = "$($OrgCode)tfstate$randomSuffix"
$stateContainer = 'tfstate'
$appName        = "$OrgCode-github-oidc-azure-platform"

$tags = @{
    Owner              = 'platform'
    CostCenter         = 'platform'
    Environment        = 'shared'
    DataClassification = 'internal'
    ManagedBy          = 'bootstrap-script'
}

Write-Host ''
Write-Host 'Bootstrap plan' -ForegroundColor Yellow
Write-Host '--------------'
[PSCustomObject]@{
    Subscription   = $subId
    Tenant         = $tenantId
    SignedInAs     = $currentUser.UserPrincipalName
    Repository     = "$GitHubOrg/$GitHubRepo"
    StateRG        = $stateRg
    StateAccount   = $stateSa
    AppRegistration = $appName
    PipelineRole   = $PipelineRole
} | Format-List

if (-not $PSCmdlet.ShouldProcess("$GitHubOrg/$GitHubRepo", 'Bootstrap Azure landing zone')) {
    Write-Host 'WhatIf specified, nothing created.' -ForegroundColor Yellow
    return
}

#endregion

#region 1. State storage ----------------------------------------------------

Write-Step "Creating state resource group: $stateRg"

$rg = Get-AzResourceGroup -Name $stateRg -ErrorAction SilentlyContinue
if ($rg) {
    Write-Detail 'Already exists, reusing.'
}
else {
    $rg = New-AzResourceGroup -Name $stateRg -Location $Location -Tag $tags
}

Write-Step "Creating state storage account: $stateSa"

# Reuse an existing bootstrap account rather than creating a second one.
$existing = Get-AzStorageAccount -ResourceGroupName $stateRg -ErrorAction SilentlyContinue |
    Where-Object { $_.StorageAccountName -like "$($OrgCode)tfstate*" } |
    Select-Object -First 1

if ($existing) {
    Write-Detail "Found existing state account $($existing.StorageAccountName), reusing."
    $sa      = $existing
    $stateSa = $existing.StorageAccountName
}
else {
    $sa = New-AzStorageAccount `
        -ResourceGroupName $stateRg `
        -Name $stateSa `
        -Location $Location `
        -SkuName 'Standard_ZRS' `
        -Kind 'StorageV2' `
        -MinimumTlsVersion 'TLS1_2' `
        -EnableHttpsTrafficOnly $true `
        -AllowBlobPublicAccess $false `
        -AllowSharedKeyAccess $false `
        -Tag $tags
}

Write-Step 'Enabling blob versioning and soft delete'

# Versioning gives you state file recovery without paying for a backup product.
# This is the cheapest insurance in the entire repo.
Update-AzStorageBlobServiceProperty `
    -ResourceGroupName $stateRg `
    -AccountName $stateSa `
    -IsVersioningEnabled $true | Out-Null

Enable-AzStorageBlobDeleteRetentionPolicy `
    -ResourceGroupName $stateRg `
    -StorageAccountName $stateSa `
    -RetentionDays 30 | Out-Null

Write-Detail 'Versioning on, 30 day soft delete on.'

Write-Step 'Granting yourself Storage Blob Data Contributor on the state account'

$saScope = $sa.Id

$existingUserRole = Get-AzRoleAssignment `
    -ObjectId $currentUser.Id `
    -RoleDefinitionName 'Storage Blob Data Contributor' `
    -Scope $saScope -ErrorAction SilentlyContinue

if ($existingUserRole) {
    Write-Detail 'Already assigned.'
}
else {
    New-AzRoleAssignment `
        -ObjectId $currentUser.Id `
        -RoleDefinitionName 'Storage Blob Data Contributor' `
        -Scope $saScope | Out-Null
}

Write-Step "Creating state container: $stateContainer"

# Shared key access is disabled, so the data plane call must use Entra auth.
$storageContext = New-AzStorageContext -StorageAccountName $stateSa -UseConnectedAccount

Wait-ForRolePropagation -Test {
    $c = Get-AzStorageContainer -Name $stateContainer -Context $storageContext -ErrorAction SilentlyContinue
    if (-not $c) {
        New-AzStorageContainer -Name $stateContainer -Context $storageContext -ErrorAction Stop | Out-Null
    }
    return $true
} | Out-Null

Write-Detail 'Container ready.'

#endregion

#region 2. Entra app registration and federated credentials -----------------

Write-Step "Creating app registration: $appName"

$app = Get-AzADApplication -DisplayName $appName -ErrorAction SilentlyContinue | Select-Object -First 1
if ($app) {
    Write-Detail 'Already exists, reusing.'
}
else {
    $app = New-AzADApplication -DisplayName $appName -SignInAudience 'AzureADMyOrg'
}

$sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue
if (-not $sp) {
    $sp = New-AzADServicePrincipal -ApplicationId $app.AppId
    Write-Detail 'Service principal created.'
}
else {
    Write-Detail 'Service principal already exists.'
}

Write-Step 'Creating federated credentials'

# Subject strings are literal matches against the OIDC token GitHub issues.
# A typo here surfaces later as AADSTS70021 with no useful detail, so treat
# these as exact.
$federatedCredentials = @(
    @{
        Name    = 'github-main'
        Subject = "repo:$GitHubOrg/$($GitHubRepo):ref:refs/heads/main"
        Purpose = 'apply on merge to main'
    }
    @{
        Name    = 'github-pull-request'
        Subject = "repo:$GitHubOrg/$($GitHubRepo):pull_request"
        Purpose = 'plan on pull request'
    }
    @{
        Name    = 'github-env-dev'
        Subject = "repo:$GitHubOrg/$($GitHubRepo):environment:dev"
        Purpose = 'nightly destroy, gated by the dev environment'
    }
)

$existingCreds = Get-AzADAppFederatedCredential -ApplicationObjectId $app.Id -ErrorAction SilentlyContinue

foreach ($cred in $federatedCredentials) {
    if ($existingCreds | Where-Object { $_.Name -eq $cred.Name }) {
        Write-Detail "$($cred.Name) already exists, skipping."
        continue
    }

    New-AzADAppFederatedCredential `
        -ApplicationObjectId $app.Id `
        -Name $cred.Name `
        -Issuer 'https://token.actions.githubusercontent.com' `
        -Subject $cred.Subject `
        -Audience 'api://AzureADTokenExchange' | Out-Null

    Write-Detail "$($cred.Name)  ->  $($cred.Purpose)"
}

#endregion

#region 3. Pipeline role assignments ----------------------------------------

Write-Step "Assigning $PipelineRole at subscription scope to the pipeline identity"

# Owner is broader than ideal. The tighter pattern is Contributor plus
# 'Role Based Access Control Administrator', but Phase 1 creates role
# assignments and policy assignments, both of which need elevated rights.
# Record the tradeoff in ADR 0001: chose breadth for a single-subscription
# environment, would scope down with PIM-eligible assignments in production.

$subScope = "/subscriptions/$subId"

$existingSpRole = Get-AzRoleAssignment `
    -ObjectId $sp.Id `
    -RoleDefinitionName $PipelineRole `
    -Scope $subScope -ErrorAction SilentlyContinue

if ($existingSpRole) {
    Write-Detail 'Already assigned.'
}
else {
    Wait-ForRolePropagation -Test {
        New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $PipelineRole -Scope $subScope -ErrorAction Stop | Out-Null
        return $true
    } -TimeoutSeconds 120 | Out-Null
}

Write-Step 'Assigning Storage Blob Data Contributor on the state account to the pipeline identity'

$existingSpSaRole = Get-AzRoleAssignment `
    -ObjectId $sp.Id `
    -RoleDefinitionName 'Storage Blob Data Contributor' `
    -Scope $saScope -ErrorAction SilentlyContinue

if ($existingSpSaRole) {
    Write-Detail 'Already assigned.'
}
else {
    New-AzRoleAssignment `
        -ObjectId $sp.Id `
        -RoleDefinitionName 'Storage Blob Data Contributor' `
        -Scope $saScope | Out-Null
}

if ($IncludeManagementGroupScope) {
    Write-Step 'Assigning Owner at the root management group'
    Write-Detail 'Required for the Phase 1 management group hierarchy.'
    Write-Detail 'You must have elevated access enabled in Entra properties first.'

    New-AzRoleAssignment `
        -ObjectId $sp.Id `
        -RoleDefinitionName 'Owner' `
        -Scope "/providers/Microsoft.Management/managementGroups/$tenantId" | Out-Null
}

#endregion

#region Output --------------------------------------------------------------

$vars = [ordered]@{
    AZURE_CLIENT_ID       = $app.AppId
    AZURE_TENANT_ID       = $tenantId
    AZURE_SUBSCRIPTION_ID = $subId
    TFSTATE_RG            = $stateRg
    TFSTATE_SA            = $stateSa
    TFSTATE_CONTAINER     = $stateContainer
}

Write-Host ''
Write-Host 'Bootstrap complete.' -ForegroundColor Green
Write-Host ''
Write-Host 'GitHub Actions repository VARIABLES' -ForegroundColor Yellow
Write-Host 'Variables, not secrets. None of these are sensitive, and treating'
Write-Host 'them as variables is a defensible point in a code review.'
Write-Host ''

$vars.GetEnumerator() | ForEach-Object {
    '  {0,-22} {1}' -f $_.Key, $_.Value
}

Write-Host ''
Write-Host 'Set them with the gh CLI:' -ForegroundColor Yellow
Write-Host ''
$vars.GetEnumerator() | ForEach-Object {
    "  gh variable set $($_.Key) --body `"$($_.Value)`" --repo $GitHubOrg/$GitHubRepo"
}

# Emit the backend config so it can be redirected straight to a file.
$backend = @"

terraform {
  backend "azurerm" {
    resource_group_name  = "$stateRg"
    storage_account_name = "$stateSa"
    container_name       = "$stateContainer"
    key                  = "dev.tfstate"
    use_azuread_auth     = true
    use_oidc             = true
  }
}
"@

Write-Host ''
Write-Host 'Backend block for environments/dev/backend.tf:' -ForegroundColor Yellow
Write-Host $backend

Write-Host 'Next steps:' -ForegroundColor Yellow
Write-Host '  1. Create the "dev" environment in GitHub repo settings.'
Write-Host '  2. Set the repository variables above.'
Write-Host '  3. Write environments/dev/backend.tf with the block above.'
Write-Host '  4. Open a PR. Plan should run and comment. That is Phase 0 done.'
Write-Host ''

# Return the values as an object so the script composes rather than only prints.
[PSCustomObject]$vars

#endregion
