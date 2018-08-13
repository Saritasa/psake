function Task {
    <#
        .SYNOPSIS
        Defines a build task to be executed by psake

        .DESCRIPTION
        This function creates a 'task' object that will be used by the psake engine to execute a build task.
        Note: There must be at least one task called 'default' in the build script

        .PARAMETER name
        The name of the task

        .PARAMETER action
        A scriptblock containing the statements to execute for the task.

        .PARAMETER preaction
        A scriptblock to be executed before the 'Action' scriptblock.
        Note: This parameter is ignored if the 'Action' scriptblock is not defined.

        .PARAMETER postaction
        A scriptblock to be executed after the 'Action' scriptblock.
        Note: This parameter is ignored if the 'Action' scriptblock is not defined.

        .PARAMETER precondition
        A scriptblock that is executed to determine if the task is executed or skipped.
        This scriptblock should return $true or $false

        .PARAMETER postcondition
        A scriptblock that is executed to determine if the task completed its job correctly.
        An exception is thrown if the scriptblock returns $false.

        .PARAMETER continueOnError
        If this switch parameter is set then the task will not cause the build to fail when an exception is thrown by the task

        .PARAMETER depends
        An array of task names that this task depends on.
        These tasks will be executed before the current task is executed.

        .PARAMETER requiredVariables
        An array of names of variables that must be set to run this task.

        .PARAMETER description
        A description of the task.

        .PARAMETER alias
        An alternate name for the task.

        .PARAMETER FromModule
        Load in the task from the specified PowerShell module.

        .PARAMETER Version
        The version of the PowerShell module to load in the task from.

        .EXAMPLE
        A sample build script is shown below:

        Task default -Depends Test

        Task Test -Depends Compile, Clean {
            "This is a test"
        }

        Task Compile -Depends Clean {
            "Compile"
        }

        Task Clean {
            "Clean"
        }

        The 'default' task is required and should not contain an 'Action' parameter.
        It uses the 'Depends' parameter to specify that 'Test' is a dependency

        The 'Test' task uses the 'Depends' parameter to specify that 'Compile' and 'Clean' are dependencies
        The 'Compile' task depends on the 'Clean' task.

        Note:
        The 'Action' parameter is defaulted to the script block following the 'Clean' task.

        An equivalent 'Test' task is shown below:

        Task Test -Depends Compile, Clean -Action {
            $testMessage
        }

        The output for the above sample build script is shown below:

        Executing task, Clean...
        Clean
        Executing task, Compile...
        Compile
        Executing task, Test...
        This is a test

        Build Succeeded!

        ----------------------------------------------------------------------
        Build Time Report
        ----------------------------------------------------------------------
        Name    Duration
        ----    --------
        Clean   00:00:00.0065614
        Compile 00:00:00.0133268
        Test    00:00:00.0225964
        Total:  00:00:00.0782496

        .LINK
        Assert
        .LINK
        Exec
        .LINK
        FormatTaskName
        .LINK
        Framework
        .LINK
        Get-PSakeScriptTasks
        .LINK
        Include
        .LINK
        Invoke-psake
        .LINK
        Properties
        .LINK
        TaskSetup
        .LINK
        TaskTearDown
    #>
    [CmdletBinding(DefaultParameterSetName = 'Normal')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$name,

        [Parameter(Position = 1)]
        [scriptblock]$action = $null,

        [Parameter(Position = 2)]
        [scriptblock]$preaction = $null,

        [Parameter(Position = 3)]
        [scriptblock]$postaction = $null,

        [Parameter(Position = 4)]
        [scriptblock]$precondition = {$true},

        [Parameter(Position = 5)]
        [scriptblock]$postcondition = {$true},

        [Parameter(Position = 6)]
        [switch]$continueOnError,

        [Parameter(Position = 7)]
        [string[]]$depends = @(),

        [Parameter(Position = 8)]
        [string[]]$requiredVariables = @(),

        [Parameter(Position = 9)]
        [string]$description = $null,

        [Parameter(Position = 10)]
        [string]$alias = $null,

        [parameter(Mandatory = $true, ParameterSetName = 'SharedTask', Position = 11)]
        [ValidateNotNullOrEmpty()]
        [string]$FromModule,

        [parameter(ParameterSetName = 'SharedTask', Position = 12)]
        [ValidateNotNullOrEmpty()]
        [version]$Version
    )

    function CreateTask {
        @{
            Name              = $Name
            DependsOn         = $depends
            PreAction         = $preaction
            Action            = $action
            PostAction        = $postaction
            Precondition      = $precondition
            Postcondition     = $postcondition
            ContinueOnError   = $continueOnError
            Description       = $description
            Duration          = [System.TimeSpan]::Zero
            RequiredVariables = $requiredVariables
            Alias             = $alias
        }
    }

    # Default tasks have no action
    if ($name -eq 'default') {
        Assert (!$action) ($msgs.error_shared_task_cannot_have_action)
    }

    # Shared tasks have no action
    if ($PSCmdlet.ParameterSetName -eq 'SharedTask') {
        Assert (!$action) ($msgs.error_shared_task_cannot_have_action -f $Name, $FromModule)
    }

    $currentContext = $psake.context.Peek()

    # Dot source the shared task module to load in its tasks
    if ($PSCmdlet.ParameterSetName -eq 'SharedTask') {

        if ($taskModule = Get-Module -Name $FromModule) {
            # Use the task module that is already loaded into the session
            if ($Version) {
                $taskModule = $taskModule | Where-Object {$_.Version -eq $Version}
            } else {
                $taskModule = $taskModule | Sort-Object -Property Version -Descending | Select-Object -First 1
            }
        } else {
            # Find the module
            $moduleSpec = @{
                ModuleName = $FromModule
            }
            if ($Version) {
                $moduleSpec.RequiredVersion = $Version
            }
            $getModuleParams = @{
                ListAvailable = $true
                ErrorAction   = 'Ignore'
                Verbose       = $false
            }
            if ($moduleSpec.RequiredVersion) {
                $getModuleParams.FullyQualifiedName = $moduleSpec
            } else {
                $getModuleParams.Name = $moduleSpec.ModuleName
            }
            $taskModule = Get-Module @getModuleParams | Sort-Object -Property Version -Descending | Select-Object -First 1
        }

        # This task references a task from a module
        # This reference task "could" include extra data about the task such as
        # additional dependOn, aliase, etc.
        # Store this task to the side so after we load the real task, we can combine
        # this extra data if nesessary
        $referenceTask = CreateTask
        Assert (-not $psake.ReferenceTasks.ContainsKey($referenceTask.Name)) ($msgs.error_duplicate_task_name -f $referenceTask.Name)
        $referenceTaskKey = $referenceTask.Name.ToLower()
        $psake.ReferenceTasks.Add($referenceTaskKey, $referenceTask)

        # Load in tasks from shared module into staging area
        Assert ($null -ne $taskModule) ($msgs.error_unknown_module -f $moduleSpec.ModuleName)
        $psakeFilePath = Join-Path -Path $taskModule.ModuleBase -ChildPath 'psakeFile.ps1'
        if (-not $psake.LoadedTaskModules.ContainsKey($psakeFilePath)) {
            Write-Debug -Message "Loading tasks from task module [$psakeFilePath]"
            . $psakeFilePath
            $psake.LoadedTaskModules.Add($psakeFilePath, $null)
        }
    } else {
        # Create new task object
        $newTask = CreateTask
        $taskKey = $newTask.Name.ToLower()

        # If this task was referenced from a parent build script
        # check to see if that reference task has extra data to add
        $refTask = $psake.ReferenceTasks.$taskKey
        if ($refTask) {
            if ($refTask.DependsOn.Count -gt 0) { $newTask.DependsOn += $refTask.DependsOn }
            if ($refTask.ContinueOnError) { $newTask.ContinueOnError = $refTask.ContinueOnError }
            if ($refTask.RequiredVariables.Count -gt 0) { $newTask.RequiredVariables += $refTask.RequiredVariables }
        }

        # Add the task to the context
        Assert (-not $currentContext.tasks.ContainsKey($taskKey)) ($msgs.error_duplicate_task_name -f $taskKey)
        Write-Debug "Adding task [$taskKey)]"
        $currentContext.tasks.$taskKey = $newTask

        if ($alias) {
            $aliasKey = $alias.ToLower()
            Assert (-not $currentContext.aliases.ContainsKey($aliasKey)) ($msgs.error_duplicate_alias_name -f $alias)
            $currentContext.aliases.$aliasKey = $newTask
        }
    }
}
