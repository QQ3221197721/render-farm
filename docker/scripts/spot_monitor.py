#!/usr/bin/env python3
"""
Spot实例中断监控模块
支持阿里云和AWS的Spot中断检测
"""
import os
import time
import urllib.request
import logging

logger = logging.getLogger('spot-monitor')

CLOUD_PROVIDER = os.getenv('CLOUD_PROVIDER', 'aliyun')

# Spot中断检测URL
SPOT_TERMINATION_URLS = {
    'aliyun': 'http://100.100.100.200/latest/meta-data/instance/spot/termination-time',
    'aws': 'http://169.254.169.254/latest/meta-data/spot/termination-time'
}

def check_spot_termination() -> bool:
    """
    检测Spot实例是否即将被回收
    阿里云和AWS都会在回收前2分钟发出通知
    """
    url = SPOT_TERMINATION_URLS.get(CLOUD_PROVIDER)
    if not url:
        return False
    
    try:
        resp = urllib.request.urlopen(url, timeout=2)
        termination_time = resp.read().decode('utf-8')
        logger.warning(f"Spot termination scheduled at: {termination_time}")
        return True
    except urllib.error.HTTPError as e:
        if e.code == 404:
            # 404表示没有中断通知
            return False
        logger.error(f"HTTP error checking spot termination: {e}")
    except Exception as e:
        # 连接超时等错误,可能是非Spot实例
        pass
    
    return False

def get_instance_metadata() -> dict:
    """获取实例元数据"""
    metadata = {}
    
    if CLOUD_PROVIDER == 'aliyun':
        base_url = 'http://100.100.100.200/latest/meta-data/'
        keys = ['instance-id', 'instance-type', 'zone-id', 'region-id']
    else:
        base_url = 'http://169.254.169.254/latest/meta-data/'
        keys = ['instance-id', 'instance-type', 'placement/availability-zone']
    
    for key in keys:
        try:
            resp = urllib.request.urlopen(f"{base_url}{key}", timeout=2)
            metadata[key] = resp.read().decode('utf-8')
        except:
            pass
    
    return metadata

def monitor_loop(callback, interval: int = 5):
    """
    持续监控Spot中断
    
    Args:
        callback: 检测到中断时调用的回调函数
        interval: 检查间隔(秒)
    """
    logger.info(f"Starting Spot monitor for {CLOUD_PROVIDER}")
    
    while True:
        if check_spot_termination():
            logger.warning("Spot termination detected!")
            callback()
            break
        time.sleep(interval)

if __name__ == '__main__':
    # 测试模式
    logging.basicConfig(level=logging.INFO)
    print(f"Cloud Provider: {CLOUD_PROVIDER}")
    print(f"Spot Termination: {check_spot_termination()}")
    print(f"Instance Metadata: {get_instance_metadata()}")
