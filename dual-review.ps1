#Requires -Version 7.0
<#
.SYNOPSIS
    Reviews the same code with Claude and Codex (GPT), optionally Copilot, and compares them.

.DESCRIPTION
    Read-only. Writes the reviews and a comparison to .reviews/<timestamp>-<branch>/ in the
    repository and adds .reviews/ to .git/info/exclude so it never ends up in a commit.

.EXAMPLE
    dual-review                     # current branch (committed + uncommitted) vs main/master
    dual-review -Base develop       # against another base branch
    dual-review -Path src/Payments  # full review of a folder instead of a diff
    dual-review -WithCopilot        # add Copilot as a third reviewer
#>
[CmdletBinding()]
param(
    [string]$Base,
    [string]$Path,
    [switch]$WithCopilot,
    # 'auto' because some Copilot plans only expose one model and reject explicit ones.
    [string]$CopilotModel = 'auto',
    [string]$ClaudeModel,
    [string]$CodexModel,
    [int]$TimeoutMinutes = 20,
    [switch]$NoSummary
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)

function Resolve-Exe([string]$Name, [string[]]$Preferred = @()) {
    foreach ($p in $Preferred) { if (Test-Path -LiteralPath $p) { return $p } }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { throw "'$Name' was not found on PATH." }
    return $cmd.Source
}

function Invoke-Git {
    $out = & git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed." }
    return $out
}

function Write-Utf8([string]$File, [string]$Text) {
    [IO.File]::WriteAllText($File, $Text, $utf8)
}

# --- Repository and scope -------------------------------------------------------------------

$repoRoot = (Invoke-Git rev-parse --show-toplevel) -replace '/', '\'
Push-Location $repoRoot
try {
    $branch = (& git rev-parse --abbrev-ref HEAD 2>$null) ?? 'detached'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $runRel = ".reviews/$stamp-$($branch -replace '[^\w.-]', '-')"
    $runDir = Join-Path $repoRoot $runRel
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null

    $exclude = Invoke-Git rev-parse --git-path info/exclude
    New-Item -ItemType Directory -Force -Path (Split-Path $exclude) | Out-Null
    if (-not (Test-Path $exclude) -or -not (Select-String -LiteralPath $exclude -SimpleMatch '.reviews/' -Quiet)) {
        Add-Content -LiteralPath $exclude -Value '.reviews/'
    }

    $scope = [Text.StringBuilder]::new()
    if ($Path) {
        $files = @(Invoke-Git ls-files -- $Path) + @(Invoke-Git ls-files --others --exclude-standard -- $Path) |
            Where-Object { $_ } | Sort-Object -Unique
        if (-not $files) { throw "No files found under '$Path'." }
        [void]$scope.AppendLine("# Review scope`n`nFull review of these files (not a diff):`n")
        $files | ForEach-Object { [void]$scope.AppendLine("- ``$_``") }
    }
    else {
        if (-not $Base) {
            $Base = 'main', 'master', 'origin/main', 'origin/master' |
                Where-Object { & git rev-parse --verify --quiet $_ 2>$null; $LASTEXITCODE -eq 0 } |
                Select-Object -First 1
            if (-not $Base) { throw "No main/master branch found. Use -Base <branch>." }
        }
        $mergeBase = Invoke-Git merge-base HEAD $Base
        $diffFile = Join-Path $runDir 'scope.diff'
        Invoke-Git diff --no-color --output=$diffFile $mergeBase | Out-Null
        $untracked = @(Invoke-Git ls-files --others --exclude-standard) | Where-Object { $_ -and -not $_.StartsWith('.reviews/') }
        if ((Get-Item $diffFile).Length -eq 0 -and -not $untracked) {
            Write-Host "Nothing to review: no changes between '$Base' and the working tree."
            Remove-Item -Recurse -Force $runDir
            return
        }
        [void]$scope.AppendLine("# Review scope`n")
        [void]$scope.AppendLine("Changes on branch ``$branch`` (committed and uncommitted) against ``$Base`` (merge base ``$mergeBase``).")
        [void]$scope.AppendLine("The full diff is in ``$runRel/scope.diff``.`n`n## Changed files`n")
        [void]$scope.AppendLine('```')
        (Invoke-Git diff --stat=200 $mergeBase) | ForEach-Object { [void]$scope.AppendLine($_) }
        [void]$scope.AppendLine('```')
        if ($untracked) {
            [void]$scope.AppendLine("`n## New untracked files (review them in full)`n")
            $untracked | ForEach-Object { [void]$scope.AppendLine("- ``$_``") }
        }
    }
    Write-Utf8 (Join-Path $runDir 'scope.md') $scope.ToString()

    $template = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'review-prompt.md')
    Write-Utf8 (Join-Path $runDir 'prompt.md') ($template -replace '\{\{RUN_DIR\}\}', $runRel)
    $instruction = "Read the file $runRel/prompt.md and follow its instructions exactly. Print only the review."

    # --- Reviewers ------------------------------------------------------------------------------

    $gitReadTools = 'git diff', 'git log', 'git show', 'git status'
    $reviewers = [Collections.Generic.List[hashtable]]::new()

    $claudeArgs = @('-p', $instruction, '--no-session-persistence')
    if ($ClaudeModel) { $claudeArgs += '--model', $ClaudeModel }
    $claudeArgs += @('--allowedTools', 'Read', 'Grep', 'Glob') + ($gitReadTools | ForEach-Object { "Bash(${_}:*)" })
    $claudeArgs += '--disallowedTools', 'Edit', 'Write', 'NotebookEdit'
    $reviewers.Add(@{ Name = 'claude'; Exe = (Resolve-Exe claude); Args = $claudeArgs; Out = 'claude.md' })

    $codexOut = Join-Path $runDir 'codex.md'
    $codexArgs = @('exec', '--sandbox', 'read-only', '--color', 'never', '--ephemeral', '-o', $codexOut)
    if ($CodexModel) { $codexArgs += '--model', $CodexModel }
    $codexArgs += $instruction
    $codexExe = Resolve-Exe codex @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\codex.exe")
    # Codex writes its final answer with -o; stdout is progress noise and goes to the log.
    $reviewers.Add(@{ Name = 'codex'; Exe = $codexExe; Args = $codexArgs; Out = $null; File = 'codex.md' })

    if ($WithCopilot) {
        $copilotArgs = @('-p', $instruction, '-s', '--no-ask-user', '--no-color', '--model', $CopilotModel)
        $copilotArgs += @('--allow-tool') + ($gitReadTools | ForEach-Object { "shell(${_}:*)" })
        $copilotArgs += '--deny-tool', 'write'
        $copilotExe = Resolve-Exe copilot @("$env:LOCALAPPDATA\GitHubCopilotCLI\copilot.exe")
        $reviewers.Add(@{ Name = "copilot ($CopilotModel)"; Exe = $copilotExe; Args = $copilotArgs; Out = 'copilot.md' })
    }

    $runOne = {
        param($Exe, $ArgList, $OutFile, $LogFile, $Cwd)
        Set-Location -LiteralPath $Cwd
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $OutputEncoding = [Text.UTF8Encoding]::new($false)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        if ($OutFile) {
            $text = $null | & $Exe @ArgList 2> $LogFile | Out-String
            [IO.File]::WriteAllText($OutFile, $text.Trim() + "`n", [Text.UTF8Encoding]::new($false))
        }
        else {
            $null | & $Exe @ArgList *> $LogFile
        }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Seconds = [math]::Round($sw.Elapsed.TotalSeconds) }
    }

    Write-Host "Reviewing on '$branch' with: $(($reviewers | ForEach-Object Name) -join ', ')"
    Write-Host "Output: $runDir"
    foreach ($r in $reviewers) {
        $key = ($r.Name -split ' ')[0]
        $r.File ??= $r.Out
        $outFile = if ($r.Out) { Join-Path $runDir $r.Out } else { $null }
        $r.Job = Start-Job -ScriptBlock $runOne -ArgumentList $r.Exe, $r.Args, $outFile, (Join-Path $runDir "$key.log"), $repoRoot
    }

    Wait-Job -Job ($reviewers | ForEach-Object Job) -Timeout ($TimeoutMinutes * 60) | Out-Null

    $succeeded = [Collections.Generic.List[hashtable]]::new()
    foreach ($r in $reviewers) {
        $key = ($r.Name -split ' ')[0]
        $file = Join-Path $runDir $r.File
        if ($r.Job.State -eq 'Running') {
            Stop-Job $r.Job
            Write-Host ("  {0,-22} TIMEOUT after {1} min" -f $r.Name, $TimeoutMinutes) -ForegroundColor Red
            continue
        }
        $result = Receive-Job $r.Job -ErrorAction SilentlyContinue | Select-Object -Last 1
        $hasOutput = (Test-Path $file) -and (Get-Item $file).Length -gt 2
        if ($result.ExitCode -eq 0 -and $hasOutput) {
            Write-Host ("  {0,-22} ok      {1,4}s  {2}" -f $r.Name, $result.Seconds, $r.File) -ForegroundColor Green
            $succeeded.Add($r)
        }
        else {
            Write-Host ("  {0,-22} FAILED  exit {1}, see {2}.log" -f $r.Name, $result.ExitCode, $key) -ForegroundColor Red
            $log = Join-Path $runDir "$key.log"
            if (Test-Path $log) { Get-Content $log -Tail 5 | ForEach-Object { Write-Host "      $_" } }
        }
        Remove-Job $r.Job -Force
    }

    # --- Comparison -----------------------------------------------------------------------------

    if ($NoSummary) { return }
    if ($succeeded.Count -lt 2) {
        Write-Host "Fewer than two reviews succeeded, so there is nothing to compare." -ForegroundColor Yellow
        return
    }

    $reviewList = ($succeeded | ForEach-Object { "- $($_.Name): ``$runRel/$($_.File)``" }) -join "`n"
    $summaryTemplate = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'summary-prompt.md')
    $summaryPrompt = $summaryTemplate -replace '\{\{REVIEWS\}\}', $reviewList -replace '\{\{RUN_DIR\}\}', $runRel
    Write-Utf8 (Join-Path $runDir 'summary-prompt.md') $summaryPrompt

    Write-Host "Comparing reviews with Claude..."
    $summaryArgs = @('-p', "Read the file $runRel/summary-prompt.md and follow its instructions exactly. Print only the comparison.",
        '--no-session-persistence', '--allowedTools', 'Read', 'Grep', 'Glob', '--disallowedTools', 'Edit', 'Write', 'NotebookEdit', 'Bash')
    if ($ClaudeModel) { $summaryArgs += '--model', $ClaudeModel }
    $job = Start-Job -ScriptBlock $runOne -ArgumentList (Resolve-Exe claude), $summaryArgs, (Join-Path $runDir 'summary.md'), (Join-Path $runDir 'summary.log'), $repoRoot
    Wait-Job $job -Timeout ($TimeoutMinutes * 60) | Out-Null
    $result = Receive-Job $job -ErrorAction SilentlyContinue | Select-Object -Last 1
    Remove-Job $job -Force
    if ($result.ExitCode -eq 0) {
        Write-Host ("Summary ({0}s): {1}" -f $result.Seconds, (Join-Path $runDir 'summary.md')) -ForegroundColor Green
    }
    else {
        Write-Host "Comparison failed, see summary.log. The individual reviews are still in $runDir" -ForegroundColor Red
    }
}
finally {
    Pop-Location
}
