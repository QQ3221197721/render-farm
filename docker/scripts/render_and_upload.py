#!/usr/bin/env python3
"""
============================================================
多云Blender渲染节点 - 主渲染脚本
功能:
  - Blender CLI渲染
  - 渲染完成自动上传至OSS/S3
  - Spot实例中断检测与检查点保存
  - Prometheus指标暴露
============================================================
"""
import os
import sys
import subprocess
import signal
import time
import json
import threading
import logging
from pathlib import Path
from datetime import datetime
from typing import Optional
from http.server import HTTPServer, BaseHTTPRequestHandler

from prometheus_client import start_http_server, Counter, Gauge, Histogram, generate_latest, CONTENT_TYPE_LATEST

# ============================================================
# 日志配置
# ============================================================
LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')
LOG_FORMAT = os.getenv('LOG_FORMAT', 'json')

if LOG_FORMAT == 'json':
    from pythonjsonlogger import jsonlogger
    handler = logging.StreamHandler()
    formatter = jsonlogger.JsonFormatter('%(asctime)s %(levelname)s %(name)s %(message)s')
    handler.setFormatter(formatter)
    logging.root.handlers = [handler]
else:
    logging.basicConfig(format='%(asctime)s [%(levelname)s] %(message)s')

logging.root.setLevel(getattr(logging, LOG_LEVEL))
logger = logging.getLogger('render-node')

# ============================================================
# Prometheus 指标
# ============================================================
RENDER_FRAMES_TOTAL = Counter(
    'render_frames_total', 
    'Total number of frames processed',
    ['status', 'job_id']
)
RENDER_DURATION = Histogram(
    'render_duration_seconds',
    'Time spent rendering a single frame',
    ['job_id'],
    buckets=(60, 120, 300, 600, 900, 1200, 1800, 3600)
)
UPLOAD_DURATION = Histogram(
    'upload_duration_seconds',
    'Time spent uploading rendered frame',
    ['job_id', 'cloud']
)
CURRENT_FRAME = Gauge(
    'current_rendering_frame',
    'Currently rendering frame number',
    ['job_id', 'pod_name']
)
SPOT_INTERRUPTIONS = Counter(
    'render_spot_interruptions_total',
    'Number of Spot instance interruptions detected',
    ['job_id', 'cloud']
)
ESTIMATED_COST = Gauge(
    'render_estimated_cost_usd',
    'Estimated cost in USD',
    ['job_id']
)

# ============================================================
# 环境变量配置
# ============================================================
class Config:
    # 云服务商
    CLOUD_PROVIDER = os.getenv('CLOUD_PROVIDER', 'aliyun')
    
    # 存储配置
    BUCKET_NAME = os.getenv('BUCKET_NAME', '')
    OSS_ENDPOINT = os.getenv('OSS_ENDPOINT', 'oss-cn-shanghai.aliyuncs.com')
    AWS_REGION = os.getenv('AWS_REGION', 'us-east-1')
    
    # Blender配置
    BLEND_FILE = os.getenv('BLEND_FILE', '/data/input/scene.blend')
    OUTPUT_DIR = os.getenv('OUTPUT_DIR', '/data/output')
    RENDER_ENGINE = os.getenv('RENDER_ENGINE', 'CYCLES')
    RENDER_DEVICE = os.getenv('RENDER_DEVICE', 'GPU')
    OUTPUT_FORMAT = os.getenv('OUTPUT_FORMAT', 'PNG')
    RESOLUTION_X = int(os.getenv('RESOLUTION_X', '3840'))
    RESOLUTION_Y = int(os.getenv('RESOLUTION_Y', '2160'))
    SAMPLES = int(os.getenv('SAMPLES', '128'))
    
    # Job配置
    JOB_ID = os.getenv('JOB_ID', 'default')
    POD_NAME = os.getenv('POD_NAME', 'unknown')
    JOB_COMPLETION_INDEX = int(os.getenv('JOB_COMPLETION_INDEX', '0'))
    
    # 检查点配置
    CHECKPOINT_ENABLED = os.getenv('CHECKPOINT_ENABLED', 'true').lower() == 'true'
    CHECKPOINT_INTERVAL = int(os.getenv('CHECKPOINT_INTERVAL', '60'))
    CHECKPOINT_PATH = os.getenv('CHECKPOINT_PATH', 'checkpoints/')
    
    # 成本估算 (USD/小时)
    SPOT_PRICE = float(os.getenv('SPOT_PRICE', '0.12'))

config = Config()

# ============================================================
# 全局状态
# ============================================================
class RenderState:
    interrupted = False
    current_frame = 0
    start_time = time.time()
    render_start_time = 0

state = RenderState()

# ============================================================
# 健康检查HTTP服务
# ============================================================
class HealthHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # 禁用请求日志
    
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
        elif self.path == '/ready':
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'READY')
        elif self.path == '/metrics':
            self.send_response(200)
            self.send_header('Content-type', CONTENT_TYPE_LATEST)
            self.end_headers()
            self.wfile.write(generate_latest())
        else:
            self.send_response(404)
            self.end_headers()

def start_health_server(port: int = 8000):
    """启动健康检查HTTP服务"""
    server = HTTPServer(('', port), HealthHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    logger.info(f"Health server started on port {port}")

# ============================================================
# Spot中断检测
# ============================================================
def check_spot_termination() -> bool:
    """检测Spot实例是否即将被回收"""
    import urllib.request
    
    try:
        if config.CLOUD_PROVIDER == 'aws':
            url = 'http://169.254.169.254/latest/meta-data/spot/termination-time'
            urllib.request.urlopen(url, timeout=2)
            return True
        elif config.CLOUD_PROVIDER == 'aliyun':
            url = 'http://100.100.100.200/latest/meta-data/instance/spot/termination-time'
            urllib.request.urlopen(url, timeout=2)
            return True
    except:
        pass
    return False

def spot_monitor_thread():
    """后台线程持续监控Spot中断"""
    while not state.interrupted:
        if check_spot_termination():
            logger.warning("Spot termination notice detected!")
            SPOT_INTERRUPTIONS.labels(
                job_id=config.JOB_ID,
                cloud=config.CLOUD_PROVIDER
            ).inc()
            state.interrupted = True
            save_checkpoint()
            break
        time.sleep(5)

# ============================================================
# 信号处理
# ============================================================
def handle_signal(signum, frame):
    """处理终止信号"""
    logger.warning(f"Received signal {signum}, saving checkpoint...")
    state.interrupted = True
    save_checkpoint()
    sys.exit(137)

signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)

# ============================================================
# 检查点机制
# ============================================================
def save_checkpoint():
    """保存渲染进度检查点"""
    if not config.CHECKPOINT_ENABLED:
        return
    
    checkpoint = {
        'job_id': config.JOB_ID,
        'pod_name': config.POD_NAME,
        'frame_index': config.JOB_COMPLETION_INDEX,
        'current_frame': state.current_frame,
        'elapsed_seconds': time.time() - state.start_time,
        'status': 'interrupted' if state.interrupted else 'in_progress',
        'timestamp': datetime.utcnow().isoformat()
    }
    
    checkpoint_file = f"{config.OUTPUT_DIR}/checkpoint.json"
    with open(checkpoint_file, 'w') as f:
        json.dump(checkpoint, f, indent=2)
    
    # 上传检查点到云存储
    try:
        remote_key = f"{config.CHECKPOINT_PATH}{config.JOB_ID}/{config.POD_NAME}.json"
        upload_to_cloud(checkpoint_file, remote_key)
        logger.info(f"Checkpoint saved: frame={state.current_frame}")
    except Exception as e:
        logger.error(f"Failed to upload checkpoint: {e}")

def load_checkpoint() -> Optional[int]:
    """加载检查点，返回应该开始的帧号"""
    checkpoint_file = f"{config.OUTPUT_DIR}/checkpoint.json"
    if os.path.exists(checkpoint_file):
        with open(checkpoint_file) as f:
            data = json.load(f)
            if data.get('status') == 'completed':
                return None  # 已完成
            return data.get('current_frame', config.JOB_COMPLETION_INDEX)
    return config.JOB_COMPLETION_INDEX

# ============================================================
# 云存储上传
# ============================================================
def upload_to_cloud(local_path: str, remote_key: str):
    """统一上传接口"""
    start = time.time()
    
    if config.CLOUD_PROVIDER == 'aliyun':
        upload_to_oss(local_path, remote_key)
    else:
        upload_to_s3(local_path, remote_key)
    
    UPLOAD_DURATION.labels(
        job_id=config.JOB_ID,
        cloud=config.CLOUD_PROVIDER
    ).observe(time.time() - start)

def upload_to_oss(local_path: str, remote_key: str):
    """上传至阿里云OSS"""
    import oss2
    
    auth = oss2.Auth(
        os.getenv('ALIBABA_CLOUD_ACCESS_KEY_ID'),
        os.getenv('ALIBABA_CLOUD_ACCESS_KEY_SECRET')
    )
    bucket = oss2.Bucket(auth, config.OSS_ENDPOINT, config.BUCKET_NAME)
    
    # 使用分片上传大文件
    file_size = os.path.getsize(local_path)
    if file_size > 100 * 1024 * 1024:  # 100MB
        oss2.resumable_upload(bucket, remote_key, local_path)
    else:
        bucket.put_object_from_file(remote_key, local_path)
    
    logger.info(f"[OSS] Uploaded: {remote_key}")

def upload_to_s3(local_path: str, remote_key: str):
    """上传至AWS S3"""
    import boto3
    from boto3.s3.transfer import TransferConfig
    
    s3 = boto3.client('s3',
        aws_access_key_id=os.getenv('AWS_ACCESS_KEY_ID'),
        aws_secret_access_key=os.getenv('AWS_SECRET_ACCESS_KEY'),
        region_name=config.AWS_REGION
    )
    
    # 多线程上传配置
    transfer_config = TransferConfig(
        multipart_threshold=100 * 1024 * 1024,
        max_concurrency=10,
        use_threads=True
    )
    
    s3.upload_file(local_path, config.BUCKET_NAME, remote_key, Config=transfer_config)
    logger.info(f"[S3] Uploaded: {remote_key}")

# ============================================================
# Blender渲染
# ============================================================
def render_frame(frame_num: int) -> bool:
    """渲染单帧"""
    state.current_frame = frame_num
    state.render_start_time = time.time()
    
    CURRENT_FRAME.labels(
        job_id=config.JOB_ID,
        pod_name=config.POD_NAME
    ).set(frame_num)
    
    output_path = f"{config.OUTPUT_DIR}/frame_{frame_num:04d}.{config.OUTPUT_FORMAT.lower()}"
    
    # 构建Blender命令
    cmd = [
        'blender',
        '-b', config.BLEND_FILE,
        '-E', config.RENDER_ENGINE,
        '-o', f"{config.OUTPUT_DIR}/frame_####",
        '-F', config.OUTPUT_FORMAT,
        '-x', '1',
        '-f', str(frame_num),
    ]
    
    # CYCLES特定参数
    if config.RENDER_ENGINE == 'CYCLES':
        cmd.extend([
            '--',
            '--cycles-device', config.RENDER_DEVICE
        ])
    
    logger.info(f"Starting render: frame={frame_num}, engine={config.RENDER_ENGINE}")
    
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=7200  # 2小时超时
        )
        
        render_time = time.time() - state.render_start_time
        RENDER_DURATION.labels(job_id=config.JOB_ID).observe(render_time)
        
        if result.returncode == 0 and os.path.exists(output_path):
            RENDER_FRAMES_TOTAL.labels(status='success', job_id=config.JOB_ID).inc()
            logger.info(f"Render completed: frame={frame_num}, time={render_time:.2f}s")
            return True
        else:
            RENDER_FRAMES_TOTAL.labels(status='failed', job_id=config.JOB_ID).inc()
            logger.error(f"Render failed: {result.stderr[-500:]}")
            return False
            
    except subprocess.TimeoutExpired:
        RENDER_FRAMES_TOTAL.labels(status='timeout', job_id=config.JOB_ID).inc()
        logger.error(f"Render timeout: frame={frame_num}")
        return False
    except Exception as e:
        RENDER_FRAMES_TOTAL.labels(status='error', job_id=config.JOB_ID).inc()
        logger.error(f"Render error: {e}")
        return False

# ============================================================
# 主函数
# ============================================================
def main():
    logger.info(f"Render node starting: job={config.JOB_ID}, pod={config.POD_NAME}")
    logger.info(f"Cloud: {config.CLOUD_PROVIDER}, Bucket: {config.BUCKET_NAME}")
    logger.info(f"Frame index: {config.JOB_COMPLETION_INDEX}")
    
    # 启动健康检查服务
    start_health_server(8000)
    
    # 启动Spot监控线程
    spot_thread = threading.Thread(target=spot_monitor_thread, daemon=True)
    spot_thread.start()
    
    # 确定要渲染的帧 (Indexed Job模式: 每个Pod渲染一帧)
    frame_to_render = config.JOB_COMPLETION_INDEX + 1  # 帧号从1开始
    
    # 检查是否有检查点
    checkpoint_frame = load_checkpoint()
    if checkpoint_frame is None:
        logger.info(f"Frame {frame_to_render} already completed, exiting")
        return
    
    logger.info(f"Will render frame: {frame_to_render}")
    
    # 执行渲染
    if state.interrupted:
        logger.warning("Interrupted before render started")
        sys.exit(137)
    
    success = render_frame(frame_to_render)
    
    if not success:
        logger.error("Render failed")
        sys.exit(1)
    
    # 上传渲染结果
    output_path = f"{config.OUTPUT_DIR}/frame_{frame_to_render:04d}.{config.OUTPUT_FORMAT.lower()}"
    remote_key = f"renders/{config.JOB_ID}/frame_{frame_to_render:04d}.{config.OUTPUT_FORMAT.lower()}"
    
    try:
        upload_to_cloud(output_path, remote_key)
    except Exception as e:
        logger.error(f"Upload failed: {e}")
        sys.exit(1)
    
    # 更新成本估算
    elapsed_hours = (time.time() - state.start_time) / 3600
    estimated_cost = elapsed_hours * config.SPOT_PRICE
    ESTIMATED_COST.labels(job_id=config.JOB_ID).set(estimated_cost)
    
    # 标记完成
    if config.CHECKPOINT_ENABLED:
        checkpoint = {
            'job_id': config.JOB_ID,
            'pod_name': config.POD_NAME,
            'frame_index': config.JOB_COMPLETION_INDEX,
            'current_frame': frame_to_render,
            'status': 'completed',
            'elapsed_seconds': time.time() - state.start_time,
            'timestamp': datetime.utcnow().isoformat()
        }
        checkpoint_file = f"{config.OUTPUT_DIR}/checkpoint.json"
        with open(checkpoint_file, 'w') as f:
            json.dump(checkpoint, f, indent=2)
    
    logger.info(f"Frame {frame_to_render} completed successfully!")

if __name__ == '__main__':
    main()
