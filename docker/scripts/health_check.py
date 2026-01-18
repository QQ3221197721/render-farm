#!/usr/bin/env python3
"""
健康检查脚本
用于Docker HEALTHCHECK和K8s探针
"""
import sys
import urllib.request
import json

def check_health():
    """检查渲染节点健康状态"""
    try:
        # 检查metrics端点
        resp = urllib.request.urlopen('http://localhost:8000/health', timeout=5)
        if resp.status == 200:
            return True
    except Exception as e:
        print(f"Health check failed: {e}", file=sys.stderr)
    return False

if __name__ == '__main__':
    if check_health():
        sys.exit(0)
    else:
        sys.exit(1)
