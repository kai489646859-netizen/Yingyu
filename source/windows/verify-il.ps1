$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$taskTool = Join-Path $taskRoot '.tools\ilverify\ilverify.exe'
$env:DOTNET_ROOT = Join-Path $taskRoot '.tools\dotnet'
$taskInspection = Join-Path $taskRoot '.tools\inspection\0.5.8-desktop'
function Invoke-StaticIl([string[]] $taskInputs, [string] $taskReferences, [string] $taskLog) {
    & $taskTool @taskInputs -r $taskReferences -s System.Private.CoreLib --statistics *> $taskLog
    $taskExit = $LASTEXITCODE
    $taskLines = Get-Content -LiteralPath $taskLog
    if ($taskLines -match 'Failed to load|Error:|Unhandled exception|Exception message') { throw "IL 校验器未完成：$taskLog" }
    if ($taskExit -notin 0, 2) { throw "IL 校验器异常退出：$taskExit" }
    $taskErrors = @($taskLines | Where-Object { $_ -like '[[]IL]: Error*' } | ForEach-Object {
        $_ -replace '\[[^\[]*\\([^\\]+\.dll) : ', '[$1 : '
    })
    $taskCounts = @($taskLines | Where-Object { $_ -like 'Methods verified:*' })
    if ($taskCounts.Count -ne $taskInputs.Count) { throw 'IL 校验器未遍历全部输入程序集。' }
    return @{ Errors = $taskErrors; Methods = @($taskCounts | ForEach-Object { [int]($_ -replace 'Methods verified: ', '') }); Exit = $taskExit }
}
$taskBase = Join-Path $taskRoot 'baseline\0.2.5-redline\installed'
$taskPrevious = Join-Path $taskRoot 'updates\0.6.5\payload'
$taskStage = Join-Path $PSScriptRoot 'payload'
$taskBaseline = Invoke-StaticIl @((Join-Path $taskBase 'Yingyu.dll'), (Join-Path $taskBase 'Yingyu.Core.dll')) (Join-Path $taskBase '*.dll') (Join-Path $taskInspection 'ilverify-original.log')
$taskOldHelper = Invoke-StaticIl @((Join-Path $taskPrevious 'Yingyu.Update.dll')) (Join-Path $taskPrevious '*.dll') (Join-Path $taskInspection 'ilverify-old-helper.log')
$taskNames = @('Yingyu', 'Yingyu.Core', 'Yingyu.Update', 'Richasy.MpvKernel.Core', 'Richasy.MpvKernel.WinUI')
$taskCurrent = Invoke-StaticIl @($taskNames | ForEach-Object { Join-Path $taskStage ($_ + '.dll') }) (Join-Path $taskStage '*.dll') (Join-Path $taskInspection 'ilverify-current.log')
$taskExpected = @($taskBaseline.Errors) + @($taskOldHelper.Errors)
$taskDifference = @(Compare-Object ($taskExpected | Sort-Object) ($taskCurrent.Errors | Sort-Object))
if ($taskDifference.Count -gt 0) { throw ('出现新增或未分类的 IL 错误，禁止打包：' + ($taskDifference | Out-String)) }
@{
    tool = 'Microsoft dotnet-ilverify 10.0.0'
    scope = $taskNames
    methodsVerified = ($taskCurrent.Methods | Measure-Object -Sum).Sum
    newVerificationErrors = 0
    inheritedUnverifiablePatterns = $taskCurrent.Errors
    comparison = 'Same four exact diagnostics in original 0.2.5 redline app/core and previously delivered helper. No broad ignore filters.'
    limitations = 'MSIL metadata verification only; does not execute application, installer or media playback.'
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'il-verification.json') -Encoding utf8
Write-Output "IL 验证完成：$((($taskCurrent.Methods | Measure-Object -Sum).Sum)) 个方法；新增错误 0；原有不可验证模式 $($taskCurrent.Errors.Count) 项，逐项与基线比对。"
$global:LASTEXITCODE = 0
