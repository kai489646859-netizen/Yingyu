$ErrorActionPreference='Stop'
$taskRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$taskDotnet=if($env:YINGYU_DOTNET){$env:YINGYU_DOTNET}else{Join-Path $taskRoot '.tools/dotnet/dotnet.exe'}
$taskPython=if($env:YINGYU_PYTHON){$env:YINGYU_PYTHON}else{'python'}
$taskAudit=if($env:YINGYU_AUDIT_DIR){$env:YINGYU_AUDIT_DIR}else{Join-Path $taskRoot '.tools/inspection/0.5.8-desktop'}
$taskInno=if($env:YINGYU_INNO_ISCC){$env:YINGYU_INNO_ISCC}else{Join-Path $taskRoot '.tools/inno/ISCC.exe'}
$taskOutput=if($env:YINGYU_OUTPUT_DIR){[IO.Path]::GetFullPath($env:YINGYU_OUTPUT_DIR)}else{Join-Path $PSScriptRoot 'out'}
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
function Assert-Exit([string]$Message){if($LASTEXITCODE -ne 0){throw $Message}}
& $taskPython (Join-Path $PSScriptRoot 'Native/static_native_audit.py')
Assert-Exit 'Native provenance, source copy, API or binary closure audit failed.'
& $taskPython (Join-Path $taskAudit 'static-package-audit.py') --freeze --source-only
Assert-Exit 'Source scope, preservation or freeze failed.'
& $taskDotnet build (Join-Path $PSScriptRoot 'Runtime/Yingyu.Update.csproj') -c Release -o (Join-Path $PSScriptRoot 'runtime-build') --nologo
Assert-Exit 'Runtime compilation failed.'
& $taskDotnet build (Join-Path $PSScriptRoot 'Patcher/Patcher.csproj') -c Release -o (Join-Path $PSScriptRoot 'patcher-build') --nologo
Assert-Exit 'Patcher compilation failed.'
& $taskDotnet (Join-Path $PSScriptRoot 'patcher-build/Patcher.dll') $taskRoot
Assert-Exit 'Payload generation failed.'
# Preserve the previously shipped optional helper-deps companion; application binding uses Yingyu.deps.json.
Copy-Item -LiteralPath (Join-Path $taskRoot 'updates/0.4.6-desktop/payload/Yingyu.Update.deps.json') -Destination (Join-Path $PSScriptRoot 'payload/Yingyu.Update.deps.json') -Force
New-Item -ItemType Directory -Force (Join-Path $PSScriptRoot 'payload/ThirdParty') | Out-Null
Copy-Item -Path (Join-Path $PSScriptRoot 'ThirdParty/*') -Destination (Join-Path $PSScriptRoot 'payload/ThirdParty') -Recurse -Force
& $taskPython (Join-Path $taskAudit 'startup-resource-audit.py')
Assert-Exit 'Startup manifest boundary audit failed.'
& $taskDotnet build (Join-Path $taskAudit 'StaticAssemblyAudit.csproj') -c Release -o (Join-Path $taskAudit 'metadata-audit') --nologo
Assert-Exit 'Metadata reader compilation failed.'
& $taskDotnet (Join-Path $taskAudit 'metadata-audit/StaticAssemblyAudit.dll') $taskRoot
Assert-Exit 'Host metadata or helper binding audit failed.'
& (Join-Path $PSScriptRoot 'verify-il.ps1')
Assert-Exit 'Static IL audit failed.'
& $taskPython (Join-Path $taskAudit 'static-package-audit.py')
Assert-Exit 'Payload or native preservation audit failed.'
New-Item -ItemType Directory -Force $taskOutput | Out-Null
& $taskInno /Qp "/DInstallerOutput=$taskOutput" (Join-Path $PSScriptRoot 'setup.iss')
Assert-Exit 'Installer compilation failed.'
& $taskPython (Join-Path $taskAudit 'static-package-audit.py') --final
Assert-Exit 'Final package audit failed.'
Get-FileHash -LiteralPath (Join-Path $taskOutput 'Yingyu-Setup-x64-0.5.8.exe') -Algorithm SHA256
# This entry compiles and packages only. Real-device/use verification belongs to
# the release record and is intentionally kept separate from build automation.
