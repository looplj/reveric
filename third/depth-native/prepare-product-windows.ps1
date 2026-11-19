param([string]$Destination = "")
$ErrorActionPreference = "Stop"
$depthRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$depthWork = Join-Path $depthRoot "build/depth-native"
New-Item -ItemType Directory -Force $depthWork | Out-Null
$ortSdk = Join-Path $depthWork "ort-sdk-windows-x64"
$ortStamp = Join-Path $ortSdk "recipe.sha256"
$requiredOperators = Join-Path $PSScriptRoot "required_operators.config"
$ortRecipe = (Get-FileHash -LiteralPath $PSCommandPath, $requiredOperators -Algorithm SHA256).Hash -join ":"
$missingSdkFiles = @("recipe.sha256", "include/onnxruntime_cxx_api.h", "lib/onnxruntime.lib",
  "lib/onnxruntime.dll", "LICENSE", "ThirdPartyNotices.txt") | Where-Object {
  !(Test-Path -LiteralPath (Join-Path $ortSdk $_) -PathType Leaf)
}
if (!$missingSdkFiles -and (Get-Content -LiteralPath $ortStamp -Raw).Trim() -eq $ortRecipe) {
  Write-Output "Reusing reduced Windows ONNX Runtime SDK: $ortSdk"
} else {
  $ortVersion = "1.31.0-build.1"
  $ortWork = Join-Path $depthWork "ort-reduced-win-$ortVersion"
  $ortSource = Join-Path $ortWork "source"
  $ortBuild = Join-Path $ortWork "build"
  if (!(Test-Path "$ortSource/.git" -PathType Container)) {
    git -c advice.detachedHead=false clone --config core.longpaths=true --depth 1 --branch "v$ortVersion" https://github.com/looplj/onnxruntime.git $ortSource
    if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime source checkout failed" }
  }
  $ortTree = git -C $ortSource rev-parse "HEAD^{tree}"
  if ($LASTEXITCODE -ne 0 -or $ortTree -ne "30de4f4306304e2420143a842acebed3707a0841") {
    throw "ONNX Runtime source does not match the pinned v$ortVersion tree."
  }

  $venv = Join-Path $ortWork "venv"
  $python = Join-Path $venv "Scripts/python.exe"
  if (!(Test-Path -LiteralPath $python -PathType Leaf)) {
    python -m venv $venv
    if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime Python environment setup failed" }
  }
  & $python -m pip install flatbuffers==25.12.19 packaging==26.3 setuptools==84.2.1
  if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime Python dependency installation failed" }
  & $python "$ortSource/tools/ci_build/reduce_op_kernels.py" $requiredOperators `
    --cmake_build_dir $ortBuild --is_extended_minimal_build_or_higher
  if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime operator reduction failed" }

  # Use the same protoc version pinned by ONNX Runtime and skip building the compiler.
  $protocArchive = Join-Path $ortWork "protoc-33.6-win64.zip"
  $protocHash = "96a83b8ee942f1046f079c43657cc09fd41f37a4e349ddb0e8ba5064c48bb5ff"
  if (!(Test-Path -LiteralPath $protocArchive -PathType Leaf)) {
    $protocDownload = "$protocArchive.part"
    Invoke-WebRequest "https://github.com/protocolbuffers/protobuf/releases/download/v33.6/protoc-33.6-win64.zip" -OutFile $protocDownload
    if ((Get-FileHash -LiteralPath $protocDownload -Algorithm SHA256).Hash -ne $protocHash) {
      throw "protoc checksum mismatch"
    }
    Move-Item -LiteralPath $protocDownload -Destination $protocArchive
  }
  if ((Get-FileHash -LiteralPath $protocArchive -Algorithm SHA256).Hash -ne $protocHash) {
    throw "protoc checksum mismatch"
  }
  $protocDirectory = Join-Path $ortWork "protoc"
  Expand-Archive -LiteralPath $protocArchive -DestinationPath $protocDirectory -Force
  $protoc = Join-Path $protocDirectory "bin/protoc.exe"

  cmake -S "$ortSource/cmake" -B $ortBuild -A x64 --compile-no-warning-as-error `
    -Donnxruntime_BUILD_SHARED_LIB=ON -Donnxruntime_BUILD_UNIT_TESTS=OFF `
    -Donnxruntime_REDUCED_OPS_BUILD=ON -Donnxruntime_DISABLE_ML_OPS=ON -Donnxruntime_DISABLE_RTTI=ON `
    -Donnxruntime_DISABLE_FLOAT8_TYPES=ON -Donnxruntime_DISABLE_OPTIONAL_TYPE=ON -Donnxruntime_DISABLE_SPARSE_TENSORS=ON `
    -Donnxruntime_USE_TELEMETRY=OFF -Donnxruntime_USE_WINDOWS_TELEMETRY=OFF -Donnxruntime_TELEMETRY_BACKEND=AUTO `
    -DONNX_USE_MSVC_STATIC_RUNTIME=OFF -Dprotobuf_MSVC_STATIC_RUNTIME=OFF -DABSL_MSVC_STATIC_RUNTIME=OFF `
    -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" `
    "-DPython_EXECUTABLE=$python" "-DONNX_CUSTOM_PROTOC_EXECUTABLE=$protoc" `
    -DCMAKE_INSTALL_INCLUDEDIR=include -DCMAKE_INSTALL_BINDIR=lib -DCMAKE_INSTALL_LIBDIR=lib
  if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime configure failed" }
  cmake --build $ortBuild --config MinSizeRel --parallel 4 -- "/p:CL_MPCount=4" "/nodeReuse:False"
  if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime build failed" }
  if (Test-Path -LiteralPath $ortSdk) {
    Remove-Item -LiteralPath $ortSdk -Recurse -Force
  }
  cmake --install $ortBuild --config MinSizeRel --prefix $ortSdk
  if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime install failed" }

  Copy-Item "$ortSdk/include/onnxruntime/*" "$ortSdk/include" -Force
  Copy-Item "$ortSource/LICENSE", "$ortSource/ThirdPartyNotices.txt" $ortSdk -Force
  Set-Content -LiteralPath $ortStamp -Value $ortRecipe
}

if (!$Destination) { $Destination = Join-Path $depthWork "product-windows" }
cmake -S $PSScriptRoot -B "$depthWork/native-windows" -A x64 -DBUILD_TESTING=OFF "-DORT_ROOT=$ortSdk"
if ($LASTEXITCODE -ne 0) { throw "Depth configure failed" }
cmake --build "$depthWork/native-windows" --config Release --parallel 4
if ($LASTEXITCODE -ne 0) { throw "Depth build failed" }
cmake --install "$depthWork/native-windows" --config Release --prefix $Destination
if ($LASTEXITCODE -ne 0) { throw "Depth install failed" }
