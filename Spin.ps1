<# 
   VM Power Off
#>

param(
    [parameter(Mandatory=$false)]
    [String] $AzureCredentialName = "Use *Default Automation Credential* Asset",
    [parameter(Mandatory=$false)]
    [String] $AzureSubscriptionName = "Use *Default Azure Subscription* Variable Value",
    [parameter(Mandatory=$false)]
    [String] $tz = "Use *Default Time Zone* Variable Value",
    [parameter(Mandatory=$false)]
    [bool]$Simulate = $false,
    [parameter(Mandatory = $false)]
    [Array] $ServerUpdateSchedule = ("16/01","17/01","23/01","24/01","13/02","14/02","20/02","21/02","13/03","14/03","20/03","21/03","17/04","18/04","24/04","25/04","14/05","15/05","16/05","22/05","23/05","11/06","12/06","13/06","19/06","20/06","16/07","17/07","18/07","14/08","15/08","17/09","18/09","19/09","25/09","26/09","15/10","16/10","17/10","12/11","13/11","14/11","20/11","21/11","17/12"),
    [parameter(Mandatory=$false)]
    [String]$FuncKeyAddBack = "Use *Func Add* Variable Value",
    [parameter(Mandatory=$false)]
    [String]$FuncKeyMoveFrom = "Use *Func Move* Variable Value"
)

$VERSION = "3.0.0"

# Define function to check current time against specified range
function CheckScheduleEntry ([string]$TimeRange, [string]$VmName)
{ 
# Initialize variables
$rangeStart, $rangeEnd, $parsedDay = $null
$tempTime = (Get-Date).ToUniversalTime()
    $tzEST = [System.TimeZoneInfo]::FindSystemTimeZoneById($tz)
    $CurrentTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($tempTime, $tzEST)
    $midnight = $currentTime.AddDays(1).Date        

try
{
   # Parse as range if contains '->'
   if($TimeRange -like "*->*")
   {
       $timeRangeComponents = $TimeRange -split "->" | ForEach-Object {$_.Trim()}
       if($timeRangeComponents.Count -eq 2)
       {
           $rangeStart = Get-Date $timeRangeComponents[0]
           $rangeEnd = Get-Date $timeRangeComponents[1]
           # Check for crossing midnight
           if($rangeStart -gt $rangeEnd)
           {
                    # If current time is between the start of range and midnight tonight, interpret start time as earlier today and end time as tomorrow
                    if($currentTime -ge $rangeStart -and $currentTime -lt $midnight)
                    {
                        $rangeEnd = $rangeEnd.AddDays(1)
                    }
                    # Otherwise interpret start time as yesterday and end time as today   
                    else
                    {
                        $rangeStart = $rangeStart.AddDays(-1)
                    }
           }
       }
       else
       {
           Write-Output "`tWARNING: Invalid time range format. Expects valid .Net DateTime-formatted start time and end time separated by '->'" 
       }
   }
   # Otherwise attempt to parse as a full day entry, e.g. 'Monday' or 'December 25' 
   else
   {
       # If specified as day of week, check if today
       if([System.DayOfWeek].GetEnumValues() -contains $TimeRange)
       {
           if($TimeRange -eq (Get-Date).DayOfWeek)
           {
               $parsedDay = Get-Date "00:00"
           }
           else
           {
               # Skip detected day of week that isn't today
           }
        }
        elseif ($TimeRange -match '^([0-1]?[0-9]|[2][0-3]):([0-5][0-9])|([0-9]pm|am)$' -and -not ($TimeRange -like '*->*'))
        {
            # Parse as time, e.g. '17:00'
            $parsedDay = $null
            $rangeStart = Get-Date $TimeRange
            $rangeEnd = $rangeStart.AddMinutes(30) # Only match this hour
        }
        else
        {
            # Otherwise attempt to parse as a date, e.g. 'December 25'
            else
            {
                $parsedDay = Get-Date $TimeRange
            }
        }
   
       if($null -ne $parsedDay)
       {
           $rangeStart = $parsedDay # Defaults to midnight
           $rangeEnd = $parsedDay.AddHours(23).AddMinutes(59).AddSeconds(59) # End of the same day
        }
    }
}
catch
{
   # Record any errors and return false by default
   Write-Output "`tWARNING: Exception encountered while parsing time range. Details: $($_.Exception.Message). Check the syntax of entry, e.g. '<StartTime> -> <EndTime>', or days/dates like 'Sunday' and 'December 25'"   
   return $false
}
# Check if current time falls within range
if (($VM_NAME -Like "*sxlx*") -or ($VM_NAME -Like "*sawn*"))
{
    ## if vm will match in 1 hour
    $PlusOneHour = $currentTime.AddHours(1)
    if($PlusOneHour -ge $rangeStart -and $currentTime -le $rangeEnd)
    {
        ## move to shutdown workspace before shutdown
        $Url = "https://crp-api.azurewebsites.net/api/azure-move-vm-from-monitor-la-workspace?code=r1TCawL88lTldx2zzkhYmi0kY4dUlFehXpVNd9o9xDgAeEsNx0HqvQ=="
        $DataHT = @{
            "vm_name" = $VirtualMachine.Name
            "resource_group_name" = $VirtualMachine.ResourceGroupName
            "subscription" = $AzureSubscriptionName
        }
        $Body = $DataHT | ConvertTo-Json
        Invoke-RestMethod -Method 'Post' -Uri $Url -Body $Body
    }
}
if($currentTime -ge $rangeStart -and $currentTime -le $rangeEnd)
{
   return $true
}
else
{
   return $false
}
} # End function CheckScheduleEntry

# Function to handle power state assertion for resource manager VMs
function AssertVirtualMachinePowerState
{
    param(
        [Object]$VirtualMachine,
        [string]$RGName,
        [string]$DesiredState,
        [Object[]]$ResourceManagerVMList,
        [Object[]]$ClassicVMList,
        [bool]$Simulate
    )

    $resourceManagerVM = $ResourceManagerVMList | Where-Object {$_.Name -eq $VirtualMachine.Name -and $_.ResourceGroupName -eq $RGName}
    AssertResourceManagerVirtualMachinePowerState -VirtualMachine $resourceManagerVM -DesiredState $DesiredState -Simulate $Simulate
}

# Function to handle power state assertion for resource manager VM
function AssertResourceManagerVirtualMachinePowerState
{
    param(
        [Object]$VirtualMachine,
        [string]$DesiredState,
        [bool]$Simulate
    )

    #Write-Host $VirtualMachine

    # Get VM with current status
    $resourceManagerVM = Get-AzVM -ResourceGroupName $VirtualMachine.ResourceGroupName -Name $VirtualMachine.Name -Status
    $currentStatus = $resourceManagerVM.Statuses | Where-Object Code -like "PowerState*" 
    $currentStatus = $currentStatus.Code -replace "PowerState/",""

    # If should be started and isn't, start VM
if($DesiredState -eq "Started" -and $currentStatus -notmatch "running")
{
        if($Simulate)
        {
            Write-Output "[$($VirtualMachine.Name)]: SIMULATION -- Would have started VM. (No action taken)"
        }
        else
        {
            Write-Output "[$($VirtualMachine.Name)]: Starting VM"
            $resourceManagerVM | Start-AzVM -NoWait > $null
            ## once vm is started move to monitor la workspace
            $Url = "https://crp-api.azurewebsites.net/api/azure-add-vm-to-monitor-la-workspace?code=QuZEEZOjpCGoyJ6kyraElbhnMcuc/OynBT7/NzzQGxnELn8LtuTVCw=="
            $DataHT = @{
                "vm_name" = $VirtualMachine.Name
                "resource_group_name" = $VirtualMachine.ResourceGroupName
                "subscription" = $AzureSubscriptionName
            }
            $Body = $DataHT | ConvertTo-Json
            Invoke-RestMethod -Method 'Post' -Uri $Url -Body $Body
        }
}
# If should be stopped and isn't, stop VM
elseif($DesiredState -eq "StoppedDeallocated" -and $currentStatus -ne "deallocated")
{
        if($Simulate)
        {
            Write-Output "[$($VirtualMachine.Name)]: SIMULATION -- Would have stopped VM. (No action taken)"
        }
        else
        {
            ## move to shutdown workspace before shutdown # change to move 1 hour before shutdown
            #$Url = "https://crp-api.azurewebsites.net/api/azure-move-vm-from-monitor-la-workspace?code=r1TCawL88lTldx2zzkhYmi0kY4dUlFehXpVNd9o9xDgAeEsNx0HqvQ=="
            #$DataHT = @{
            #    "vm_name" = $VirtualMachine.Name
            #    "resource_group_name" = $VirtualMachine.ResourceGroupName
            #    "subscription" = $AzureSubscriptionName
            #}
            #$Body = $DataHT | ConvertTo-Json
            #Invoke-RestMethod -Method 'Post' -Uri $Url -Body $Body
            Write-Output "[$($VirtualMachine.Name)]: Stopping VM"
            $resourceManagerVM | Stop-AzVM -NoWait -Force > $null
        }
}

    # Otherwise, current power state is correct
    else
    {
        Write-Output "[$($VirtualMachine.Name)]: Current power state [$currentStatus] is correct."
    }
}

# Main runbook content
try
{
    # Retrieve time zone name from variable asset if not specified
    if($tz -eq "Use *Default Time Zone* Variable Value")
    {
        $tz = Get-AutomationVariable -Name "Default Time Zone"
        if($tz.length -gt 0)
        {
            Write-Output "Specified time zone: [$tz]"
        }
        else
        {
            throw "No time zone was specified, and no variable asset with name 'Default Time Zone' was found. Either specify a time zone or define the default using a variable setting"
        }
    }

$tempTime = (Get-Date).ToUniversalTime()
    $tzEST = [System.TimeZoneInfo]::FindSystemTimeZoneById($tz)
    $CurrentTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($tempTime, $tzEST)

    Write-Output "Runbook started. Version: $VERSION"
    if($Simulate)
    {
        Write-Output "*** Running in SIMULATE mode. No power actions will be taken. ***"
    }
    else
    {
        Write-Output "*** Running in LIVE mode. Schedules will be enforced. ***"
    }
    Write-Output "Current $tz time [$($currentTime.ToString("dddd, yyyy MMM dd HH:mm:ss"))] will be checked against schedules"

    # Retrieve subscription name from variable asset if not specified
    if($AzureSubscriptionName -eq "Use *Default Azure Subscription* Variable Value")
    {
        $AzureSubscriptionName = Get-AutomationVariable -Name "Default Azure Subscription"
        if($AzureSubscriptionName.length -gt 0)
        {
            Write-Output "Specified subscription name/ID: [$AzureSubscriptionName]"
        }
        else
        {
            throw "No subscription name was specified, and no variable asset with name 'Default Azure Subscription' was found. Either specify an Azure subscription name or define the default using a variable setting"
        }
    }

    # Retrieve credential
    Write-Output "Get the runas account"
    $RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection"
    if($RunAsConnection) {
        Write-Output ("Logging in to Azure using the runas account...")
        Add-AzAccount -ServicePrincipal -TenantId $RunAsConnection.TenantId -ApplicationId $RunAsConnection.ApplicationId `
            -CertificateThumbprint $RunAsConnection.CertificateThumbprint > $null

    } else {
        Write-Output "No runas account was found, trying with other ways"
        write-output "Specified credential asset name: [$AzureCredentialName]"
        if($AzureCredentialName -eq "Use *Default Automation Credential* asset")
        {
            # By default, look for "Default Automation Credential" asset
            $azureCredential = Get-AutomationPSCredential -Name "Default Automation Credential"
            if($null -ne $azureCredential)
            {
                Write-Output "Attempting to authenticate as: [$($azureCredential.UserName)]"
            }
            else
            {
                throw "No automation credential name was specified, and no credential asset with name 'Default Automation Credential' was found. Either specify a stored credential name or define the default using a credential asset"
            }
        }
        else
        {
            # A different credential name was specified, attempt to load it
            $azureCredential = Get-AutomationPSCredential -Name $AzureCredentialName
            if($null -eq $azureCredential)
            {
                throw "Failed to get credential with name [$AzureCredentialName]"
            }
        }

        # Connect to Azure using credential asset (AzureRM)
        $account = Connect-AzAccount -Credential $azureCredential

        # Check for returned userID, indicating successful authentication
        #if(Get-AzureAccount -Name $azureCredential.UserName)
        if($account.Context.Account.Id -eq $azureCredential.UserName)
        {
            Write-Output "Successfully authenticated as user: [$($azureCredential.UserName)]"
        }
        else
        {
            throw "Authentication failed for credential [$($azureCredential.UserName)]. Ensure a valid Azure Active Directory user account is specified which is configured as subscription owner (modern portal) on the target subscription. Verify you can log into the Azure portal using these credentials."
        }
}

    # Validate subscription
    $subscriptions = @(Get-AzSubscription | Where-Object {$_.Name -eq $AzureSubscriptionName -or $_.Id -eq $AzureSubscriptionName})
    if($subscriptions.Count -eq 1)
    {
        # Set working subscription
        $targetSubscription = $subscriptions | Select-Object -First 1
        $targetSubscription | Select-AzSubscription > $null

        # Connect via Azure Resource Manager if not already done using the runas account
        if(!$RunAsConnection) {
            Connect-AzAccount -Credential $azureCredential -SubscriptionId $targetSubscription.SubscriptionId > $null
        }

        #$currentSubscription = Get-AzSubscription
        Write-Output "Working against subscription: $($targetSubscription.Name) ($($targetSubscription.SubscriptionId))"
    }
    else
    {
        if($subscription.Count -eq 0)
        {
            throw "No accessible subscription found with name or ID [$AzureSubscriptionName]. Check the runbook parameters and ensure user is a co-administrator on the target subscription."
        }
        elseif($subscriptions.Count -gt 1)
        {
            throw "More than one accessible subscription found with name or ID [$AzureSubscriptionName]. Please ensure your subscription names are unique, or specify the ID instead"
        }
    }

    # Get a list of all virtual machines in subscription
    $resourceManagerVMList = Get-AzVm | Sort-Object Name

    # Get resource groups that are tagged for automatic shutdown of resources
$taggedResourceGroups = @(Get-AzResourceGroup | Where-Object {$_.Tags.Count -gt 0 -and $_.Tags.AutoShutdownSchedule})
    $taggedResourceGroupNames = @($taggedResourceGroups | Select-Object -ExpandProperty ResourceGroupName)
    Write-Output "Found [$($taggedResourceGroups.Count)] schedule-tagged resource groups in subscription" 

    # For each VM, determine
    #  - Is it directly tagged for shutdown or member of a tagged resource group
    #  - Is the current time within the tagged schedule 
    # Then assert its correct power state based on the assigned schedule (if present)
    Write-Output "Processing [$($resourceManagerVMList.Count)] virtual machines found in subscription"
    foreach($vm in $resourceManagerVMList)
    {
        $schedule = $null

        # Check for direct tag or group-inherited tag
        if($vm.Tags -and $vm.Tags.AutoShutdownSchedule)
        {
            # VM has direct tag (possible for resource manager deployment model VMs). Prefer this tag schedule.
            $schedule = $vm.Tags.AutoShutdownSchedule
            Write-Output "[$($vm.Name)]: Found direct VM schedule tag with value: $schedule"

            # check if current day matches scheduled OS Patching 
            $currentDate = Get-Date
            $currentMonth = $currentDate.Month
            $currentDay = $currentDate.Day

            $currentDayMonth = "$currentDay/$currentMonth"

            if ($ServerUpdateSchedule.contains($currentDayMonth)) {
                # start vm if it is not already running
                AssertVirtualMachinePowerState -VirtualMachine $vm -RGName $vm.ResourceGroupName -DesiredState "Started" -ResourceManagerVMList $resourceManagerVMList -ClassicVMList $classicVMList -Simulate $Simulate
                
            }
        }
        elseif($taggedResourceGroupNames -contains $vm.ResourceGroupName)
        {
            # VM belongs to a tagged resource group. Use the group tag
            $parentGroup = $taggedResourceGroups | Where-Object ResourceGroupName -eq $vm.ResourceGroupName
            $schedule = $parentGroup.Tags.AutoShutdownSchedule
            Write-Output "[$($vm.Name)]: Found parent resource group schedule tag with value: $schedule"
        }
        else
        {
            # No direct or inherited tag. Skip this VM.
            Write-Output "[$($vm.Name)]: Not tagged for shutdown directly or via membership in a tagged resource group. Skipping this VM."
            continue
        }

        # Check that tag value was succesfully obtained
        if($null -eq $schedule)
        {
            Write-Output "[$($vm.Name)]: Failed to get tagged schedule for virtual machine. Skipping this VM."
            continue
        }

        # Parse the ranges in the Tag value. Expects a string of comma-separated time ranges, or a single time range
$timeRangeList = @($schedule -split "," | ForEach-Object {$_.Trim()})
   
        # Check each range against the current time to see if any schedule is matched
$scheduleMatched = $false
        $matchedSchedule = $null
foreach($entry in $timeRangeList)
{
   if((CheckScheduleEntry -TimeRange $entry -VmName $vm.Name) -eq $true)
   {
       $scheduleMatched = $true
                $matchedSchedule = $entry
       break
   }
}

        # Enforce desired state for group resources based on result. 
if($scheduleMatched)
{
            # Schedule is matched. Shut down the VM if it is running. 
            Write-Output "[$($vm.Name)]: Current time [$currentTime] falls within the scheduled shutdown range [$matchedSchedule]"
            
            # check if current day matches scheduled OS Patching 
            $currentDate = Get-Date
            $currentMonth = $currentDate.Month
            $currentDay = $currentDate.Day

            $currentDayMonth = "$currentDay/$currentMonth"

            if ($ServerUpdateSchedule.contains($currentDayMonth)) {
                # start vm if it is not already running
                Write-Output "[$($vm.Name)]: Current time [$currentTime] falls within the scheduled shutdown range [$matchedSchedule], date is a scheduled server update day, vm will be started if shutdown"
                AssertVirtualMachinePowerState -VirtualMachine $vm -RGName $vm.ResourceGroupName -DesiredState "Started" -ResourceManagerVMList $resourceManagerVMList -ClassicVMList $classicVMList -Simulate $Simulate
                
            } else {
                AssertVirtualMachinePowerState -VirtualMachine $vm -RGName $vm.ResourceGroupName -DesiredState "StoppedDeallocated" -ResourceManagerVMList $resourceManagerVMList -ClassicVMList $classicVMList -Simulate $Simulate
            }
}
else
{
            # If the tag consists of a single date should the machine never be started
            try {
                if (Get-Date($schedule)) {
                    Write-Output "[$($vm.Name)]: Current time [$currentTime] falls outside the scheduled shutdown range [$schedule], single time so not changing the state."

                    # check if current day matches scheduled OS Patching 
                    $currentDate = Get-Date
                    $currentMonth = $currentDate.Month
                    $currentDay = $currentDate.Day

                    $currentDayMonth = "$currentDay/$currentMonth"

                    if ($ServerUpdateSchedule.contains($currentDayMonth)) {
                        Write-Output "[$($vm.Name)]: Current time [$currentTime] falls within the scheduled shutdown range [$matchedSchedule], date is a scheduled server update day, vm will be started if shutdown"
                        AssertVirtualMachinePowerState -VirtualMachine $vm -RGName $vm.ResourceGroupName -DesiredState "Started" -ResourceManagerVMList $resourceManagerVMList -ClassicVMList $classicVMList -Simulate $Simulate
                    }
                }
            } catch {
                Write-Output "[$($vm.Name)]: Current time falls outside of all scheduled shutdown ranges."
                AssertVirtualMachinePowerState -VirtualMachine $vm -RGName $vm.ResourceGroupName -DesiredState "Started" -ResourceManagerVMList $resourceManagerVMList -ClassicVMList $classicVMList -Simulate $Simulate
            }
        }
        # check if current day matches scheduled OS Patching 
        #$currentDate = Get-Date -Format "dd/MM/yyyy"
        $currentMonth = Get-Date -Format "MM"
        $currentDay = Get-Date -Format "dd"

        $currentDayMonth = "$currentDay/$currentMonth"

        if ($ServerUpdateSchedule.contains($currentDayMonth)) {
            # start vm if it is not already running
            Write-Output "[$($vm.Name)]: Current time [$currentTime] falls within the scheduled shutdown range [$matchedSchedule], date is a scheduled server update day, vm will be started if shutdown"
            AssertVirtualMachinePowerState -VirtualMachine $vm -RGName $vm.ResourceGroupName -DesiredState "Started" -ResourceManagerVMList $resourceManagerVMList -ClassicVMList $classicVMList -Simulate $Simulate
            
        } else {
            Write-Output "$currentDayMonth does not match with a value in $ServerUpdateSchedule"
        }
    }
    Write-Output "Finished processing virtual machine schedules"
}
catch
{
    $errorMessage = $_.Exception.Message
    $line = $_.InvocationInfo.ScriptLineNumber
    throw "Unexpected exception: $errorMessage at $line"
}
finally
{
    $tempTime = (Get-Date).ToUniversalTime()
    $EndTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($tempTime, $tzEST)
    Write-Output "Runbook finished (Duration: $(("{0:hh\:mm\:ss}" -f ($EndTime - $currentTime))))"
}

