<# 
.SYNOPSIS
    多云离线渲染农场 - Windows PowerShell 部署脚本
.DESCRIPTION
    支持阿里云ACK / AWS EKS 的一键部署
.EXAMPLE
    .\deploy.ps1 -Action deploy -CloudProvider aliyun
#>

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("deploy", "status", "logs", "cleanup", "build", "help")]
    [string]$Action = "help",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("aliyun", "aws")]
    [string]$CloudProvider = "aliyun",
    
    [Parameter(Mandatory=$false)]
    [string]$Namespace = "render-jobs",
    
    [Parameter(Mandatory=$false)]
    [string]$ReleaseName = "render-farm",
    
    [Parameter(Mandatory=$false)]
    [string]$JobId = "job-$(Get-Date -Format 'yyyyMMddHHmmss')",
    
    [Parameter(Mandatory=$false)]
    [string]$BlendFile = "",
    
    [Parameter(Mandatory=$false)]
    [int]$FrameStart = 1,
    
    [Parameter(Mandatory=$false)]
    [int]$FrameEnd = 100,
    
    [Parameter(Mandatory=$false)]
    [int]$Parallelism = 12
)

# 颜色输出函数
function Write-Info { Write-Host "[INFO] $args" -ForegroundColor Green }
function Write-Warn { Write-Host "[WARN] $args" -ForegroundColor Yellow }
function Write-Err { Write-Host "[ERROR] $args" -ForegroundColor Red }

# 检查依赖
function Test-Dependencies {
    Write-Info "检查依赖工具..."
    
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Write-Err "kubectl 未安装"
        exit 1
    }
    
    if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
        Write-Err "helm 未安装"
        exit 1
    }
    
    # 检查K8s集群连接
    $null = kubectl cluster-info 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "无法连接K8s集群，请检查kubeconfig"
        exit 1
    }
    
    Write-Info "依赖检查通过"
}

# 创建命名空间
function New-RenderNamespace {
    Write-Info "创建命名空间: $Namespace"
    kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -
}

# 创建云凭证
function New-CloudCredentials {
    Write-Info "创建云凭证Secret..."
    
    if ($CloudProvider -eq "aliyun") {
        $ak = $env:ALIYUN_AK
        $sk = $env:ALIYUN_SK
        
        if ([string]::IsNullOrEmpty($ak) -or [string]::IsNullOrEmpty($sk)) {
            Write-Err "请设置 ALIYUN_AK 和 ALIYUN_SK 环境变量"
            exit 1
        }
        
        kubectl create secret generic cloud-credentials `
            --namespace $Namespace `
            --from-literal=ALIBABA_CLOUD_ACCESS_KEY_ID="$ak" `
            --from-literal=ALIBABA_CLOUD_ACCESS_KEY_SECRET="$sk" `
            --dry-run=client -o yaml | kubectl apply -f -
    }
    else {
        $ak = $env:AWS_AK
        $sk = $env:AWS_SK
        
        if ([string]::IsNullOrEmpty($ak) -or [string]::IsNullOrEmpty($sk)) {
            Write-Err "请设置 AWS_AK 和 AWS_SK 环境变量"
            exit 1
        }
        
        kubectl create secret generic cloud-credentials `
            --namespace $Namespace `
            --from-literal=AWS_ACCESS_KEY_ID="$ak" `
            --from-literal=AWS_SECRET_ACCESS_KEY="$sk" `
            --dry-run=client -o yaml | kubectl apply -f -
    }
    
    Write-Info "云凭证创建完成"
}

# 部署Helm Chart
function Deploy-HelmChart {
    Write-Info "部署Helm Chart..."
    
    $ScriptDir = Split-Path -Parent $MyInvocation.ScriptName
    $ChartDir = Join-Path (Split-Path -Parent $ScriptDir) "helm\render-farm"
    
    if ($CloudProvider -eq "aliyun") {
        $Bucket = $env:OSS_BUCKET
        $Endpoint = if ($env:OSS_ENDPOINT) { $env:OSS_ENDPOINT } else { "oss-cn-shanghai-internal.aliyuncs.com" }
    }
    else {
        $Bucket = $env:S3_BUCKET
        $Region = if ($env:AWS_REGION) { $env:AWS_REGION } else { "us-east-1" }
    }
    
    $Completions = $FrameEnd - $FrameStart + 1
    
    helm upgrade --install $ReleaseName $ChartDir `
        --namespace $Namespace `
        --set global.cloudProvider="$CloudProvider" `
        --set global.jobId="$JobId" `
        --set render.blendFile="$BlendFile" `
        --set render.outputBucket="$Bucket" `
        --set render.frameStart="$FrameStart" `
        --set render.frameEnd="$FrameEnd" `
        --set render.parallelism="$Parallelism" `
        --set render.completions="$Completions" `
        --wait --timeout 10m
    
    Write-Info "Helm部署完成"
}

# 查看状态
function Show-RenderStatus {
    Write-Info "渲染任务状态:"
    Write-Host ""
    kubectl get jobs -n $Namespace -l job-id=$JobId
    Write-Host ""
    kubectl get pods -n $Namespace -l job-id=$JobId --sort-by=.status.startTime
}

# 查看日志
function Show-RenderLogs {
    $PodName = kubectl get pods -n $Namespace -l job-id=$JobId -o jsonpath='{.items[0].metadata.name}' 2>$null
    if ($PodName) {
        kubectl logs -n $Namespace $PodName -f
    }
    else {
        Write-Warn "没有找到运行中的Pod"
    }
}

# 清理资源
function Remove-RenderResources {
    Write-Warn "清理渲染任务..."
    helm uninstall $ReleaseName -n $Namespace 2>$null
    kubectl delete jobs -n $Namespace -l job-id=$JobId 2>$null
    Write-Info "清理完成"
}

# 构建Docker镜像
function Build-DockerImage {
    Write-Info "构建Docker镜像..."
    
    $ScriptDir = Split-Path -Parent $MyInvocation.ScriptName
    $DockerDir = Join-Path (Split-Path -Parent $ScriptDir) "docker"
    
    if ($CloudProvider -eq "aliyun") {
        $ImageRepo = if ($env:IMAGE_REPO) { $env:IMAGE_REPO } else { "registry.cn-shanghai.aliyuncs.com/render-farm/blender-node" }
        
        # 登录阿里云镜像仓库
        if ($env:ALIYUN_AK -and $env:ALIYUN_SK) {
            Write-Info "登录阿里云容器镜像服务..."
            docker login --username="$($env:ALIYUN_AK)" --password="$($env:ALIYUN_SK)" registry.cn-shanghai.aliyuncs.com
        }
    }
    else {
        $ImageRepo = if ($env:IMAGE_REPO) { $env:IMAGE_REPO } else { "$($env:AWS_ACCOUNT_ID).dkr.ecr.us-east-1.amazonaws.com/blender-node" }
        
        # 登录AWS ECR
        if ($env:AWS_REGION) {
            Write-Info "登录AWS ECR..."
            $ecrPassword = aws ecr get-login-password --region $env:AWS_REGION
            $ecrPassword | docker login --username AWS --password-stdin "$($env:AWS_ACCOUNT_ID).dkr.ecr.$($env:AWS_REGION).amazonaws.com"
        }
    }
    
    $ImageTag = if ($env:IMAGE_TAG) { $env:IMAGE_TAG } else { "3.6-gpu" }
    $FullImage = "${ImageRepo}:${ImageTag}"
    
    Write-Info "构建镜像: $FullImage"
    Push-Location $DockerDir
    try {
        docker build -t $FullImage .
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Docker构建失败"
            exit 1
        }
        
        Write-Info "推送镜像: $FullImage"
        docker push $FullImage
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Docker推送失败"
            exit 1
        }
        
        Write-Info "镜像构建完成: $FullImage"
    }
    finally {
        Pop-Location
    }
}

# 显示帮助
function Show-Help {
    @"
多云离线渲染农场 - PowerShell 部署脚本

用法: .\deploy.ps1 -Action <命令> [参数]

命令:
  deploy      一键部署渲染任务
  status      查看渲染状态
  logs        查看渲染日志
  cleanup     清理渲染资源
  build       构建Docker镜像
  help        显示帮助信息

参数:
  -CloudProvider    云服务商 (aliyun/aws), 默认: aliyun
  -Namespace        K8s命名空间, 默认: render-jobs
  -JobId            任务ID, 默认: 自动生成
  -BlendFile        Blender文件路径 (oss://... 或 s3://...)
  -FrameStart       起始帧, 默认: 1
  -FrameEnd         结束帧, 默认: 100
  -Parallelism      并发度, 默认: 12

环境变量:
  # 阿里云
  `$env:ALIYUN_AK      阿里云AccessKey ID
  `$env:ALIYUN_SK      阿里云AccessKey Secret
  `$env:OSS_BUCKET     OSS存储桶名称
  `$env:OSS_ENDPOINT   OSS端点

  # AWS
  `$env:AWS_AK         AWS Access Key ID
  `$env:AWS_SK         AWS Secret Access Key
  `$env:AWS_REGION     AWS区域
  `$env:S3_BUCKET      S3存储桶名称

示例:
  # 阿里云部署
  `$env:ALIYUN_AK = "your-ak"
  `$env:ALIYUN_SK = "your-sk"
  `$env:OSS_BUCKET = "my-render-bucket"
  .\deploy.ps1 -Action deploy -CloudProvider aliyun -BlendFile "oss://bucket/scene.blend"

  # AWS部署
  `$env:AWS_AK = "your-ak"
  `$env:AWS_SK = "your-sk"
  `$env:S3_BUCKET = "my-render-bucket"
  .\deploy.ps1 -Action deploy -CloudProvider aws -BlendFile "s3://bucket/scene.blend"
"@
}

# 主入口
switch ($Action) {
    "deploy" {
        Test-Dependencies
        New-RenderNamespace
        New-CloudCredentials
        Deploy-HelmChart
        Show-RenderStatus
    }
    "status" {
        Show-RenderStatus
    }
    "logs" {
        Show-RenderLogs
    }
    "cleanup" {
        Remove-RenderResources
    }
    "build" {
        Test-Dependencies
        Build-DockerImage
    }
    "help" {
        Show-Help
    }
    default {
        Show-Help
    }
}
