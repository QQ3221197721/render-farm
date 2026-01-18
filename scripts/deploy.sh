#!/bin/bash
# ============================================================
# 多云离线渲染农场 - 一键部署脚本
# 支持阿里云ACK / AWS EKS
# ============================================================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================
# 配置参数 (请根据实际情况修改)
# ============================================================
CLOUD_PROVIDER="${CLOUD_PROVIDER:-aliyun}"  # aliyun / aws
NAMESPACE="${NAMESPACE:-render-jobs}"
RELEASE_NAME="${RELEASE_NAME:-render-farm}"
JOB_ID="${JOB_ID:-job-$(date +%Y%m%d%H%M%S)}"

# 阿里云配置
ALIYUN_AK="${ALIYUN_AK:-}"
ALIYUN_SK="${ALIYUN_SK:-}"
OSS_BUCKET="${OSS_BUCKET:-}"
OSS_ENDPOINT="${OSS_ENDPOINT:-oss-cn-shanghai-internal.aliyuncs.com}"

# AWS配置
AWS_AK="${AWS_AK:-}"
AWS_SK="${AWS_SK:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
S3_BUCKET="${S3_BUCKET:-}"

# 渲染配置
BLEND_FILE="${BLEND_FILE:-}"
FRAME_START="${FRAME_START:-1}"
FRAME_END="${FRAME_END:-100}"
PARALLELISM="${PARALLELISM:-12}"

# ============================================================
# 检查依赖
# ============================================================
check_dependencies() {
    log_info "检查依赖工具..."
    
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl 未安装"
        exit 1
    fi
    
    if ! command -v helm &> /dev/null; then
        log_error "helm 未安装"
        exit 1
    fi
    
    # 检查K8s集群连接
    if ! kubectl cluster-info &> /dev/null; then
        log_error "无法连接K8s集群，请检查kubeconfig"
        exit 1
    fi
    
    log_info "依赖检查通过"
}

# ============================================================
# 创建命名空间
# ============================================================
create_namespace() {
    log_info "创建命名空间: $NAMESPACE"
    kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
}

# ============================================================
# 创建云凭证Secret
# ============================================================
create_secrets() {
    log_info "创建云凭证Secret..."
    
    if [ "$CLOUD_PROVIDER" == "aliyun" ]; then
        if [ -z "$ALIYUN_AK" ] || [ -z "$ALIYUN_SK" ]; then
            log_error "请设置 ALIYUN_AK 和 ALIYUN_SK 环境变量"
            exit 1
        fi
        
        kubectl create secret generic cloud-credentials \
            --namespace $NAMESPACE \
            --from-literal=ALIBABA_CLOUD_ACCESS_KEY_ID="$ALIYUN_AK" \
            --from-literal=ALIBABA_CLOUD_ACCESS_KEY_SECRET="$ALIYUN_SK" \
            --dry-run=client -o yaml | kubectl apply -f -
    else
        if [ -z "$AWS_AK" ] || [ -z "$AWS_SK" ]; then
            log_error "请设置 AWS_AK 和 AWS_SK 环境变量"
            exit 1
        fi
        
        kubectl create secret generic cloud-credentials \
            --namespace $NAMESPACE \
            --from-literal=AWS_ACCESS_KEY_ID="$AWS_AK" \
            --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SK" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi
    
    log_info "云凭证创建完成"
}

# ============================================================
# 构建并推送Docker镜像
# ============================================================
build_image() {
    log_info "构建Docker镜像..."
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    DOCKER_DIR="$SCRIPT_DIR/../docker"
    
    if [ "$CLOUD_PROVIDER" == "aliyun" ]; then
        IMAGE_REPO="${IMAGE_REPO:-registry.cn-shanghai.aliyuncs.com/render-farm/blender-node}"
    else
        IMAGE_REPO="${IMAGE_REPO:-your-account.dkr.ecr.us-east-1.amazonaws.com/blender-node}"
    fi
    
    IMAGE_TAG="${IMAGE_TAG:-3.6-gpu}"
    FULL_IMAGE="$IMAGE_REPO:$IMAGE_TAG"
    
    cd "$DOCKER_DIR"
    docker build -t "$FULL_IMAGE" .
    docker push "$FULL_IMAGE"
    
    log_info "镜像推送完成: $FULL_IMAGE"
}

# ============================================================
# 部署Helm Chart
# ============================================================
deploy_helm() {
    log_info "部署Helm Chart..."
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CHART_DIR="$SCRIPT_DIR/../helm/render-farm"
    
    if [ "$CLOUD_PROVIDER" == "aliyun" ]; then
        BUCKET="$OSS_BUCKET"
        BUCKET_ENDPOINT="$OSS_ENDPOINT"
    else
        BUCKET="$S3_BUCKET"
        BUCKET_ENDPOINT=""
    fi
    
    helm upgrade --install $RELEASE_NAME "$CHART_DIR" \
        --namespace $NAMESPACE \
        --set global.cloudProvider="$CLOUD_PROVIDER" \
        --set global.jobId="$JOB_ID" \
        --set render.blendFile="$BLEND_FILE" \
        --set render.outputBucket="$BUCKET" \
        --set render.frameStart="$FRAME_START" \
        --set render.frameEnd="$FRAME_END" \
        --set render.parallelism="$PARALLELISM" \
        --set render.completions="$((FRAME_END - FRAME_START + 1))" \
        --set aliyun.accessKeyId="$ALIYUN_AK" \
        --set aliyun.accessKeySecret="$ALIYUN_SK" \
        --set aliyun.ossEndpoint="$OSS_ENDPOINT" \
        --set aws.accessKeyId="$AWS_AK" \
        --set aws.secretAccessKey="$AWS_SK" \
        --set aws.region="$AWS_REGION" \
        --wait --timeout 10m
    
    log_info "Helm部署完成"
}

# ============================================================
# 查看渲染状态
# ============================================================
show_status() {
    log_info "渲染任务状态:"
    echo ""
    kubectl get jobs -n $NAMESPACE -l job-id=$JOB_ID
    echo ""
    kubectl get pods -n $NAMESPACE -l job-id=$JOB_ID --sort-by=.status.startTime
}

# ============================================================
# 查看日志
# ============================================================
show_logs() {
    POD_NAME=$(kubectl get pods -n $NAMESPACE -l job-id=$JOB_ID -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$POD_NAME" ]; then
        kubectl logs -n $NAMESPACE $POD_NAME -f
    else
        log_warn "没有找到运行中的Pod"
    fi
}

# ============================================================
# 清理资源
# ============================================================
cleanup() {
    log_warn "清理渲染任务..."
    helm uninstall $RELEASE_NAME -n $NAMESPACE || true
    kubectl delete jobs -n $NAMESPACE -l job-id=$JOB_ID || true
    log_info "清理完成"
}

# ============================================================
# 帮助信息
# ============================================================
show_help() {
    cat << EOF
多云离线渲染农场 - 部署脚本

用法: $0 [命令]

命令:
  deploy      一键部署渲染任务
  status      查看渲染状态
  logs        查看渲染日志
  cleanup     清理渲染资源
  build       构建Docker镜像
  help        显示帮助信息

环境变量:
  CLOUD_PROVIDER    云服务商 (aliyun/aws), 默认: aliyun
  NAMESPACE         K8s命名空间, 默认: render-jobs
  JOB_ID            任务ID, 默认: 自动生成
  
  # 阿里云
  ALIYUN_AK         阿里云AccessKey ID
  ALIYUN_SK         阿里云AccessKey Secret
  OSS_BUCKET        OSS存储桶名称
  OSS_ENDPOINT      OSS端点
  
  # AWS
  AWS_AK            AWS Access Key ID
  AWS_SK            AWS Secret Access Key
  AWS_REGION        AWS区域
  S3_BUCKET         S3存储桶名称
  
  # 渲染
  BLEND_FILE        Blender文件路径 (oss://... 或 s3://...)
  FRAME_START       起始帧, 默认: 1
  FRAME_END         结束帧, 默认: 100
  PARALLELISM       并发度, 默认: 12

示例:
  # 阿里云部署
  export CLOUD_PROVIDER=aliyun
  export ALIYUN_AK=your-ak
  export ALIYUN_SK=your-sk
  export OSS_BUCKET=my-render-bucket
  export BLEND_FILE=oss://my-bucket/scene.blend
  $0 deploy

  # AWS部署
  export CLOUD_PROVIDER=aws
  export AWS_AK=your-ak
  export AWS_SK=your-sk
  export S3_BUCKET=my-render-bucket
  export BLEND_FILE=s3://my-bucket/scene.blend
  $0 deploy
EOF
}

# ============================================================
# 主入口
# ============================================================
main() {
    case "${1:-}" in
        deploy)
            check_dependencies
            create_namespace
            create_secrets
            deploy_helm
            show_status
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs
            ;;
        cleanup)
            cleanup
            ;;
        build)
            build_image
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

main "$@"
