#!/usr/bin/env python3
"""
Sing-box 代理协议完整测试环境
集成延迟、带宽、性能测试，支持多协议对比分析
"""

import asyncio
import json
import time
import subprocess
import psutil
import aiohttp
import socket
import statistics
import os
import sys
from datetime import datetime
from typing import Dict, List, Tuple, Optional
from dataclasses import dataclass, asdict
from pathlib import Path

@dataclass
class TestResult:
    """测试结果数据结构"""
    protocol: str
    timestamp: str
    latency_ms: float
    bandwidth_mbps: float
    cpu_usage_percent: float
    memory_usage_mb: float
    connection_success_rate: float
    packet_loss_percent: float
    jitter_ms: float
    throughput_score: float

@dataclass
class ComprehensiveReport:
    """综合测试报告"""
    test_summary: Dict
    protocol_rankings: List[Dict]
    detailed_results: List[TestResult]
    recommendations: List[str]
    test_environment: Dict

class ProtocolTester:
    def __init__(self, config_file: str = "test_config.json"):
        self.config_file = config_file
        self.results = []
        self.test_start_time = datetime.now()
        self.load_config()
        
    def load_config(self):
        """加载测试配置"""
        default_config = {
            "server": {
                "domain": "284072.xyz",
                "protocols": {
                    "hysteria2": {"port": 36712, "type": "UDP"},
                    "vless": {"port": 8443, "type": "TCP"},
                    "vmess": {"port": 8444, "type": "TCP"},
                    "shadowsocks": {"port": 8388, "type": "TCP"},
                    "tuic": {"port": 8445, "type": "UDP"},
                    "trojan": {"port": 8446, "type": "TCP"}
                }
            },
            "test_settings": {
                "test_duration_seconds": 30,
                "iterations_per_test": 10,
                "target_websites": [
                    "https://www.google.com",
                    "https://www.youtube.com",
                    "https://github.com",
                    "https://httpbin.org/ip"
                ],
                "bandwidth_test_file_size_mb": 10,
                "concurrent_connections": 3
            },
            "client_settings": {
                "http_proxy_port": 1081,
                "socks_proxy_port": 1080,
                "client_executable": "./singbox_client/bin/sing-box",
                "config_dir": "./singbox_client/configs"
            }
        }
        
        if os.path.exists(self.config_file):
            with open(self.config_file, 'r', encoding='utf-8') as f:
                self.config = json.load(f)
        else:
            self.config = default_config
            self.save_config()
    
    def save_config(self):
        """保存测试配置"""
        with open(self.config_file, 'w', encoding='utf-8') as f:
            json.dump(self.config, f, indent=2, ensure_ascii=False)
    
    async def check_client_status(self) -> bool:
        """检查客户端运行状态"""
        try:
            # 检查进程
            for proc in psutil.process_iter(['name', 'cmdline']):
                if 'sing-box' in proc.info['name']:
                    return True
            
            # 检查端口
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(1)
                result = sock.connect_ex(('127.0.0.1', self.config['client_settings']['http_proxy_port']))
                sock.close()
                return result == 0
            except:
                return False
        except:
            return False
    
    async def start_client(self, protocol: str) -> bool:
        """启动指定协议的客户端"""
        try:
            # 停止现有客户端
            await self.stop_client()
            
            # 等待停止完成
            await asyncio.sleep(2)
            
            # 构建启动命令
            client_exec = self.config['client_settings']['client_executable']
            config_file = f"{self.config['client_settings']['config_dir']}/{protocol}.json"
            
            if not os.path.exists(config_file):
                print(f"配置文件不存在: {config_file}")
                return False
            
            # 启动新客户端
            cmd = [client_exec, "run", "-c", config_file]
            
            # 检测操作系统
            if sys.platform == "win32":
                # Windows
                subprocess.Popen(cmd, creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
            else:
                # Unix-like
                subprocess.Popen(cmd, start_new_session=True)
            
            # 等待启动
            await asyncio.sleep(5)
            
            # 验证启动成功
            return await self.check_client_status()
            
        except Exception as e:
            print(f"启动客户端失败: {e}")
            return False
    
    async def stop_client(self):
        """停止客户端"""
        try:
            for proc in psutil.process_iter(['name', 'pid']):
                if 'sing-box' in proc.info['name']:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except psutil.TimeoutExpired:
                        proc.kill()
        except:
            pass
    
    async def test_latency(self, protocol: str, iterations: int = 10) -> Dict:
        """测试延迟性能"""
        print(f"  测试 {protocol} 延迟性能...")
        
        latencies = []
        success_count = 0
        proxy_url = f"http://127.0.0.1:{self.config['client_settings']['http_proxy_port']}"
        
        for i in range(iterations):
            try:
                start_time = time.perf_counter()
                
                timeout = aiohttp.ClientTimeout(total=10)
                connector = aiohttp.TCPConnector()
                
                async with aiohttp.ClientSession(
                    connector=connector, 
                    timeout=timeout
                ) as session:
                    async with session.get(
                        'https://httpbin.org/ip',
                        proxy=proxy_url
                    ) as response:
                        if response.status == 200:
                            end_time = time.perf_counter()
                            latency = (end_time - start_time) * 1000
                            latencies.append(latency)
                            success_count += 1
                
            except Exception as e:
                print(f"    延迟测试失败 {i+1}: {e}")
            
            await asyncio.sleep(0.1)
        
        if latencies:
            return {
                'avg_latency_ms': statistics.mean(latencies),
                'min_latency_ms': min(latencies),
                'max_latency_ms': max(latencies),
                'jitter_ms': statistics.stdev(latencies) if len(latencies) > 1 else 0,
                'success_rate': success_count / iterations,
                'packet_loss_percent': (iterations - success_count) / iterations * 100
            }
        else:
            return {
                'avg_latency_ms': float('inf'),
                'min_latency_ms': float('inf'),
                'max_latency_ms': float('inf'),
                'jitter_ms': 0,
                'success_rate': 0,
                'packet_loss_percent': 100
            }
    
    async def test_bandwidth(self, protocol: str) -> Dict:
        """测试带宽性能"""
        print(f"  测试 {protocol} 带宽性能...")
        
        file_size_mb = self.config['test_settings']['bandwidth_test_file_size_mb']
        test_urls = [
            f"https://httpbin.org/bytes/{file_size_mb * 1024 * 1024}",
            f"https://httpbin.org/bytes/{file_size_mb * 1024 * 1024 // 2}"
        ]
        
        speeds = []
        proxy_url = f"http://127.0.0.1:{self.config['client_settings']['http_proxy_port']}"
        
        for url in test_urls:
            try:
                start_time = time.perf_counter()
                
                timeout = aiohttp.ClientTimeout(total=60)
                connector = aiohttp.TCPConnector()
                
                async with aiohttp.ClientSession(
                    connector=connector,
                    timeout=timeout
                ) as session:
                    async with session.get(url, proxy=proxy_url) as response:
                        if response.status == 200:
                            data = await response.read()
                            end_time = time.perf_counter()
                            
                            duration = end_time - start_time
                            size_mb = len(data) / (1024 * 1024)
                            speed_mbps = (size_mb * 8) / duration  # Mbps
                            speeds.append(speed_mbps)
                            
            except Exception as e:
                print(f"    带宽测试失败: {e}")
        
        if speeds:
            return {
                'avg_bandwidth_mbps': statistics.mean(speeds),
                'max_bandwidth_mbps': max(speeds),
                'throughput_score': statistics.mean(speeds) * 10  # 简化评分
            }
        else:
            return {
                'avg_bandwidth_mbps': 0,
                'max_bandwidth_mbps': 0,
                'throughput_score': 0
            }
    
    def get_resource_usage(self) -> Dict:
        """获取资源使用情况"""
        try:
            cpu_percent = 0
            memory_mb = 0
            
            for proc in psutil.process_iter(['name', 'cpu_percent', 'memory_info']):
                if 'sing-box' in proc.info['name']:
                    cpu_percent += proc.info['cpu_percent'] or 0
                    memory_mb += proc.info['memory_info'].rss / (1024 * 1024)
            
            return {
                'cpu_usage_percent': cpu_percent,
                'memory_usage_mb': memory_mb
            }
        except:
            return {
                'cpu_usage_percent': 0,
                'memory_usage_mb': 0
            }
    
    async def test_protocol(self, protocol: str) -> TestResult:
        """测试单个协议的完整性能"""
        print(f"\n开始测试协议: {protocol}")
        
        # 启动客户端
        if not await self.start_client(protocol):
            print(f"  {protocol} 客户端启动失败")
            return TestResult(
                protocol=protocol,
                timestamp=datetime.now().isoformat(),
                latency_ms=float('inf'),
                bandwidth_mbps=0,
                cpu_usage_percent=0,
                memory_usage_mb=0,
                connection_success_rate=0,
                packet_loss_percent=100,
                jitter_ms=0,
                throughput_score=0
            )
        
        print(f"  {protocol} 客户端启动成功")
        
        # 等待稳定
        await asyncio.sleep(3)
        
        # 延迟测试
        latency_results = await self.test_latency(
            protocol, 
            self.config['test_settings']['iterations_per_test']
        )
        
        # 带宽测试
        bandwidth_results = await self.test_bandwidth(protocol)
        
        # 资源使用测试
        resource_usage = self.get_resource_usage()
        
        # 创建测试结果
        result = TestResult(
            protocol=protocol,
            timestamp=datetime.now().isoformat(),
            latency_ms=latency_results['avg_latency_ms'],
            bandwidth_mbps=bandwidth_results['avg_bandwidth_mbps'],
            cpu_usage_percent=resource_usage['cpu_usage_percent'],
            memory_usage_mb=resource_usage['memory_usage_mb'],
            connection_success_rate=latency_results['success_rate'],
            packet_loss_percent=latency_results['packet_loss_percent'],
            jitter_ms=latency_results['jitter_ms'],
            throughput_score=bandwidth_results['throughput_score']
        )
        
        print(f"  {protocol} 测试完成")
        print(f"    延迟: {result.latency_ms:.2f}ms")
        print(f"    带宽: {result.bandwidth_mbps:.2f}Mbps")
        print(f"    成功率: {result.connection_success_rate:.1%}")
        
        return result
    
    async def run_comprehensive_test(self) -> ComprehensiveReport:
        """运行完整的协议对比测试"""
        print("开始完整协议测试...")
        print(f"测试配置: {len(self.config['server']['protocols'])} 个协议")
        
        results = []
        
        # 逐个测试协议
        for protocol in self.config['server']['protocols'].keys():
            try:
                result = await self.test_protocol(protocol)
                results.append(result)
                
                # 测试间隔
                await asyncio.sleep(2)
                
            except Exception as e:
                print(f"测试 {protocol} 时出错: {e}")
        
        # 停止客户端
        await self.stop_client()
        
        # 生成报告
        return self.generate_report(results)
    
    def generate_report(self, results: List[TestResult]) -> ComprehensiveReport:
        """生成综合测试报告"""
        print("\n生成测试报告...")
        
        # 按性能排序
        valid_results = [r for r in results if r.latency_ms != float('inf')]
        
        # 延迟排序 (越低越好)
        latency_ranking = sorted(valid_results, key=lambda x: x.latency_ms)
        
        # 带宽排序 (越高越好)
        bandwidth_ranking = sorted(valid_results, key=lambda x: x.bandwidth_mbps, reverse=True)
        
        # 稳定性排序 (成功率越高越好)
        stability_ranking = sorted(valid_results, key=lambda x: x.connection_success_rate, reverse=True)
        
        # 综合评分 (加权平均)
        def calculate_score(result):
            if result.latency_ms == float('inf'):
                return 0
            
            latency_score = max(0, 100 - result.latency_ms / 10)  # 延迟越低分数越高
            bandwidth_score = min(100, result.bandwidth_mbps * 2)  # 带宽越高分数越高
            stability_score = result.connection_success_rate * 100  # 稳定性分数
            
            return (latency_score * 0.3 + bandwidth_score * 0.4 + stability_score * 0.3)
        
        for result in valid_results:
            result.throughput_score = calculate_score(result)
        
        overall_ranking = sorted(valid_results, key=lambda x: x.throughput_score, reverse=True)
        
        # 生成推荐
        recommendations = self.generate_recommendations(overall_ranking)
        
        # 测试摘要
        test_summary = {
            'total_protocols_tested': len(results),
            'successful_tests': len(valid_results),
            'test_duration_minutes': (datetime.now() - self.test_start_time).total_seconds() / 60,
            'best_latency_protocol': latency_ranking[0].protocol if latency_ranking else None,
            'best_bandwidth_protocol': bandwidth_ranking[0].protocol if bandwidth_ranking else None,
            'most_stable_protocol': stability_ranking[0].protocol if stability_ranking else None,
            'overall_best_protocol': overall_ranking[0].protocol if overall_ranking else None
        }
        
        # 协议排名
        protocol_rankings = [
            {
                'rank': i + 1,
                'protocol': result.protocol,
                'overall_score': result.throughput_score,
                'latency_ms': result.latency_ms,
                'bandwidth_mbps': result.bandwidth_mbps,
                'stability_percent': result.connection_success_rate * 100
            }
            for i, result in enumerate(overall_ranking)
        ]
        
        # 测试环境信息
        test_environment = {
            'test_date': datetime.now().isoformat(),
            'server_domain': self.config['server']['domain'],
            'test_iterations': self.config['test_settings']['iterations_per_test'],
            'bandwidth_test_size_mb': self.config['test_settings']['bandwidth_test_file_size_mb'],
            'target_websites_count': len(self.config['test_settings']['target_websites'])
        }
        
        return ComprehensiveReport(
            test_summary=test_summary,
            protocol_rankings=protocol_rankings,
            detailed_results=results,
            recommendations=recommendations,
            test_environment=test_environment
        )
    
    def generate_recommendations(self, ranked_results: List[TestResult]) -> List[str]:
        """生成使用建议"""
        recommendations = []
        
        if not ranked_results:
            recommendations.append("所有协议测试失败，请检查服务器配置和网络连接")
            return recommendations
        
        best = ranked_results[0]
        
        # 综合推荐
        recommendations.append(f"综合性能最佳: {best.protocol}")
        
        # 延迟敏感应用
        latency_best = min(ranked_results, key=lambda x: x.latency_ms)
        if latency_best.latency_ms < 200:
            recommendations.append(f"延迟敏感应用(游戏/实时通信)推荐: {latency_best.protocol} ({latency_best.latency_ms:.1f}ms)")
        
        # 带宽密集应用
        bandwidth_best = max(ranked_results, key=lambda x: x.bandwidth_mbps)
        if bandwidth_best.bandwidth_mbps > 10:
            recommendations.append(f"高带宽应用(视频/下载)推荐: {bandwidth_best.protocol} ({bandwidth_best.bandwidth_mbps:.1f}Mbps)")
        
        # 稳定性要求
        stability_best = max(ranked_results, key=lambda x: x.connection_success_rate)
        if stability_best.connection_success_rate > 0.9:
            recommendations.append(f"稳定性优先推荐: {stability_best.protocol} ({stability_best.connection_success_rate:.1%}成功率)")
        
        # 资源效率
        resource_best = min(ranked_results, key=lambda x: x.cpu_usage_percent + x.memory_usage_mb/100)
        recommendations.append(f"资源消耗最低: {resource_best.protocol} (CPU: {resource_best.cpu_usage_percent:.1f}%, 内存: {resource_best.memory_usage_mb:.1f}MB)")
        
        return recommendations
    
    def export_report(self, report: ComprehensiveReport, filename: str = None):
        """导出测试报告"""
        if filename is None:
            filename = f"protocol_test_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        
        report_data = {
            'test_summary': report.test_summary,
            'protocol_rankings': report.protocol_rankings,
            'detailed_results': [asdict(result) for result in report.detailed_results],
            'recommendations': report.recommendations,
            'test_environment': report.test_environment
        }
        
        with open(filename, 'w', encoding='utf-8') as f:
            json.dump(report_data, f, indent=2, ensure_ascii=False)
        
        print(f"\n测试报告已导出: {filename}")
    
    def print_report(self, report: ComprehensiveReport):
        """打印测试报告"""
        print("\n" + "="*80)
        print("Sing-box 协议性能测试报告")
        print("="*80)
        
        # 测试摘要
        print(f"\n📊 测试摘要:")
        print(f"  测试协议数量: {report.test_summary['total_protocols_tested']}")
        print(f"  成功测试数量: {report.test_summary['successful_tests']}")
        print(f"  测试用时: {report.test_summary['test_duration_minutes']:.1f}分钟")
        print(f"  综合最佳协议: {report.test_summary['overall_best_protocol']}")
        
        # 协议排名
        print(f"\n🏆 协议性能排名:")
        for ranking in report.protocol_rankings:
            print(f"  {ranking['rank']}. {ranking['protocol']:<12} "
                  f"总分: {ranking['overall_score']:.1f} "
                  f"延迟: {ranking['latency_ms']:.1f}ms "
                  f"带宽: {ranking['bandwidth_mbps']:.1f}Mbps "
                  f"稳定性: {ranking['stability_percent']:.1f}%")
        
        # 使用建议
        print(f"\n💡 使用建议:")
        for i, rec in enumerate(report.recommendations, 1):
            print(f"  {i}. {rec}")
        
        # 详细结果
        print(f"\n📋 详细测试结果:")
        for result in report.detailed_results:
            if result.latency_ms != float('inf'):
                print(f"\n  {result.protocol}:")
                print(f"    延迟: {result.latency_ms:.2f}ms (抖动: {result.jitter_ms:.2f}ms)")
                print(f"    带宽: {result.bandwidth_mbps:.2f}Mbps")
                print(f"    成功率: {result.connection_success_rate:.1%}")
                print(f"    丢包率: {result.packet_loss_percent:.1f}%")
                print(f"    CPU使用: {result.cpu_usage_percent:.1f}%")
                print(f"    内存使用: {result.memory_usage_mb:.1f}MB")
            else:
                print(f"\n  {result.protocol}: 测试失败")

async def main():
    """主函数"""
    import argparse
    
    parser = argparse.ArgumentParser(description='Sing-box 协议性能测试套件')
    parser.add_argument('--config', default='test_config.json', help='测试配置文件')
    parser.add_argument('--protocol', help='测试单个协议')
    parser.add_argument('--output', help='输出文件名')
    parser.add_argument('--iterations', type=int, default=10, help='每个测试的迭代次数')
    
    args = parser.parse_args()
    
    # 创建测试器
    tester = ProtocolTester(args.config)
    
    # 更新配置
    if args.iterations:
        tester.config['test_settings']['iterations_per_test'] = args.iterations
        tester.save_config()
    
    try:
        if args.protocol:
            # 测试单个协议
            print(f"测试单个协议: {args.protocol}")
            result = await tester.test_protocol(args.protocol)
            print(f"\n测试结果:")
            print(f"  延迟: {result.latency_ms:.2f}ms")
            print(f"  带宽: {result.bandwidth_mbps:.2f}Mbps")
            print(f"  成功率: {result.connection_success_rate:.1%}")
        else:
            # 完整测试
            report = await tester.run_comprehensive_test()
            tester.print_report(report)
            tester.export_report(report, args.output)
            
    except KeyboardInterrupt:
        print("\n测试被用户中断")
        await tester.stop_client()
    except Exception as e:
        print(f"测试过程中出错: {e}")
        await tester.stop_client()

if __name__ == "__main__":
    asyncio.run(main())