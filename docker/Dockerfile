# ============================================================
# 多云Blender渲染节点 - 生产级Dockerfile
# 支持GPU(CUDA)渲染 + 自动上传OSS/S3 + Spot中断处理
# ============================================================

# 基础镜像: 官方Blender GPU镜像
FROM nytimes/blender:3.6-gpu-ubuntu18.04 AS base

LABEL maintainer="devops@render-farm.io"
LABEL version="1.0.0"
LABEL description="Multi-cloud Blender render node with auto-upload and Spot tolerance"

# 设置环境变量
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# 安装系统依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    python3-dev \
    curl \
    wget \
    unzip \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# 升级pip
RUN pip3 install --upgrade pip setuptools wheel

# 安装Python依赖
RUN pip3 install --no-cache-dir \
    boto3==1.28.0 \
    oss2==2.18.1 \
    prometheus-client==0.17.1 \
    requests==2.31.0 \
    python-json-logger==2.0.7

# 创建工作目录
RUN mkdir -p /opt/scripts /data/input /data/output

# 复制渲染脚本
COPY scripts/render_and_upload.py /opt/scripts/
COPY scripts/health_check.py /opt/scripts/
COPY scripts/spot_monitor.py /opt/scripts/

# 设置脚本权限
RUN chmod +x /opt/scripts/*.py

# 创建非root用户
RUN useradd -m -s /bin/bash render && \
    chown -R render:render /data /opt/scripts

# 暴露Prometheus指标端口
EXPOSE 8000

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python3 /opt/scripts/health_check.py || exit 1

# 切换到非root用户
USER render

# 工作目录
WORKDIR /data

# 入口点
ENTRYPOINT ["python3", "/opt/scripts/render_and_upload.py"]
