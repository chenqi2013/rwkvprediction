"""Export complete API response examples and their data definitions as JSON."""
import argparse
import json
import re
import zipfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener
from zoneinfo import ZoneInfo


def timestamp():
    return datetime.now(ZoneInfo('Asia/Shanghai')).isoformat(timespec='seconds')


def capture(base_url, label, method, path, body=None):
    request = Request(
        base_url + path,
        method=method,
        data=json.dumps(body, ensure_ascii=False).encode('utf-8') if body is not None else None,
        headers={'Content-Type': 'application/json'},
    )
    opener = build_opener(ProxyHandler({}))
    try:
        with opener.open(request, timeout=90) as response:
            status = response.status
            payload = json.load(response)
    except HTTPError as error:
        with error:
            status = error.code
            payload = json.load(error)
    return dict(label=label, captured_at=timestamp(), request=dict(method=method, path=path, body=body),
                status_code=status, response=payload)


def write_request_files(document, directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    files = []
    for index, record in enumerate(document['responses'], start=1):
        request = record['request']
        endpoint = request['path'].split('?')[0].strip('/')
        endpoint = re.sub(r'[^a-zA-Z0-9_-]', '_', endpoint)
        filename = f'{index:02d}_{request["method"]}_{endpoint}.json'
        destination = directory / filename
        destination.write_text(json.dumps(record, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')
        files.append(destination)
    archive = directory.with_suffix('.zip')
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as package:
        for destination in files:
            package.write(destination, destination.name)
    return files, archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', default='http://127.0.0.1:8787')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    base_url = args.base_url.rstrip('/')
    requests = [
        ('后端健康状态', 'GET', '/health'),
        ('原有五个精选标的报价', 'GET', '/v1/assets'),
    ]
    searches = [
        ('股票名称搜索：茅台', dict(q='茅台', kind='股票', limit=50, offset=0)),
        ('股票代码搜索：600519', dict(q='600519', kind='股票', limit=50, offset=0)),
        ('同代码的股票与指数：000001', dict(q='000001', limit=50, offset=0)),
        ('ETF 搜索：510050', dict(q='510050', kind='ETF', limit=50, offset=0)),
        ('指数搜索：399006', dict(q='399006', kind='指数', limit=50, offset=0)),
        ('所有类别列表第一页', dict(q='', limit=50, offset=0)),
        ('所有类别列表第二页', dict(q='', limit=50, offset=50)),
    ]
    requests.extend((label, 'GET', '/v1/instruments?' + urlencode(parameters)) for label, parameters in searches)
    identities = [
        ('贵州茅台：股票', 'sh-stock-600519'),
        ('平安银行：股票', 'sz-stock-000001'),
        ('上证50ETF：ETF', 'sh-etf-510050'),
        ('创业板指：指数', 'sz-index-399006'),
        ('沪深300ETF：原有标的', 'sh-etf-510300'),
        ('创业板ETF：原有标的', 'sz-etf-159915'),
        ('科创50ETF：原有标的', 'sh-etf-588000'),
        ('沪深300：原有标的', 'sh-index-000300'),
        ('上证指数：原有标的', 'sh-index-000001'),
        ('旧客户端数字代码兼容：000001 仍为上证指数', '000001'),
    ]
    requests.extend((label, 'GET', '/v1/markets/' + identity) for label, identity in identities)
    with ThreadPoolExecutor(max_workers=4) as pool:
        responses = list(pool.map(lambda request: capture(base_url, *request), requests))
    stock = next(record for record in responses if record['request']['path'] == '/v1/markets/sh-stock-600519')
    if stock['status_code'] != 200:
        raise RuntimeError(f'无法获取股票示例：{stock["response"]}')
    snapshot = stock['response']
    delivery_body = dict(symbol=snapshot['asset']['symbol'], instrument_id=snapshot['asset']['id'],
                         prediction_id=snapshot['predictions']['20']['id'], confidence=95, channel='in_app')
    responses.append(capture(base_url, '创建一条演示下发回执：茅台、20 日、95% 区间',
                             'POST', '/v1/deliveries', delivery_body))
    responses.append(capture(base_url, '当前服务器全部下发记录（包含本次演示回执）', 'GET', '/v1/deliveries'))
    responses.append(capture(base_url, '错误响应示例：不支持的标的类别', 'GET', '/v1/instruments?kind=unsupported'))
    responses.append(capture(base_url, '错误响应示例：未知标的', 'GET', '/v1/markets/UNKNOWN'))
    document = dict(
        title='RWKV 金融预测：当前全部接口的完整响应示例',
        exported_at=timestamp(),
        base_url=base_url,
        phone_base_url_at_export='http://192.168.1.89:8787',
        scope=dict(
            description='覆盖当前 6 种方法与路径组合；提供多个参数示例，每条 response 均为接口实际响应，未裁剪历史点或预测点。',
            limitation='这是全部接口的响应样例集，不是所有股票与全市场历史的批量数据库；搜索列表按实际分页响应保留。',
            side_effect='导出时 POST /v1/deliveries 创建一条本地演示回执，不发送外部通知。',
            endpoints=['GET /health', 'GET /v1/assets', 'GET /v1/instruments',
                       'GET /v1/markets/{instrument_id}', 'POST /v1/deliveries', 'GET /v1/deliveries'],
        ),
        data_definitions=dict(
            search=dict(
                source='AKShare 股票、ETF、指数名单；只返回标的元数据，不包含实时价格。',
                query_parameters=dict(q='名称或代码包含匹配，也支持 sh600519 这样的市场前缀',
                                      kind='可省略，或为 股票、ETF、指数', limit='1–100，默认 50', offset='从 0 开始的分页偏移'),
                fields=dict(id='市场-类别-六位代码，例如 sz-stock-000001；请求行情与保存自选时使用完整 id',
                            symbol='六位代码；不同市场和类别可能重复', name='标的名称',
                            kind='股票 / ETF / 指数', market='sh 上交所 / sz 深交所 / bj 北交所',
                            subtitle='交易所或标的补充信息', currency='CNY 人民币',
                            total='匹配总数', has_more='是否还有下一页', warnings='名单过期或部分数据源不可用时的提示'),
                collision_example='000001 同时可匹配 sh-index-000001 上证指数与 sz-stock-000001 平安银行。',
                refresh='名单缓存 24 小时；部分名单不可用时返回 warnings，全部不可用时返回 502。',
            ),
            history=dict(
                source='真实 AKShare 日线，优先东方财富，失败后使用新浪备用源；不自动替换成模拟行情。',
                granularity='每个已完成交易日一个点，不是分时、逐笔或分钟线。',
                adjustment='不复权，price_adjustment=none。',
                window='最近最多 61 个完整交易日，按 date 升序；新上市标的使用可用历史，少于 2 日时报错。',
                cutoff='北京时间 15:10 前排除当日未完成日线；行情日期以 as_of 和 history 最后一个 date 为准。',
                fields=dict(date='交易日，YYYY-MM-DD', close='当日真实收盘价，单位 CNY',
                            volume='上游成交量数值，沿用 AKShare 对应来源单位，尚未统一为手或股；不是成交额'),
                chart='当前历史曲线直接以 history[].date 为横轴、history[].close 为纵轴。',
                last_point='history 最后一个 close 与 asset.price 一致。',
                ohlc='当前 history 只含 date、close、volume，不含逐日开高低；asset.open/high/low 为最后交易日的开高低。',
                cache='每个标的行情缓存 300 秒，fetch 时间与实际收盘时间分别返回。',
            ),
            quote=dict(
                asset='最后完整交易日的行情摘要，包含标的身份和价格。',
                price='最后一根日线的收盘价；ETF 通常展示 3 位小数，股票与指数展示 2 位。',
                previous_close='前一完整交易日收盘价。',
                change_percent='(price / previous_close - 1) × 100；1.25 表示 +1.25%。',
                open_high_low='最后完整交易日开盘价、最高价、最低价。',
                volume='asset.volume 是格式化成交额文本，如 76.77亿；与 history[].volume 成交量含义不同，缺失时为 --。',
                source='akshare 仅表示真实行情来源，不表示预测真实。',
                market_vendor='eastmoney 或 sina，表示实际 AKShare 上游来源。',
                as_of='行情所属收盘时间，带 +08:00 时区。',
                fetched_at='后端获取行情的时间，不等于行情交易时间。',
            ),
            predictions=dict(
                source='模拟数据，RWKV 尚未接入；以真实收盘价缩放演示路径，不是 MA/RSI 等真实白盒因子预测。',
                horizons='predictions 的键 5、20、60 分别包含该周期全部预测点。',
                points='points[].date 为未来演示交易日，当前只排除周末，未排除交易所节假日。',
                p025_p975='模拟 95% 中央预测区间下沿与上沿。',
                p10_p90='模拟 80% 中央预测区间下沿与上沿。',
                p25_p75='模拟中间 50% 区间。',
                p50='模拟中位走势。',
                trend_and_probability='trend、up_probability 为模拟设定，不是实测趋势或已校准概率。',
                explanation_drivers_scenarios='解读、驱动因素、情景及其概率均为模拟。',
                backtest_usage='回测指标、输入输出 Token、耗时均为示例，不是实际模型测量。',
            ),
            deliveries=dict(
                request='使用实际快照的 symbol、instrument_id、prediction_id，confidence 为 80 或 95，channel 为 in_app 或 webhook_demo。',
                response='返回并持久化当时的预测摘要、区间、时间与来源。',
                status='delivered 仅表示本地演示回执已保存，不代表外部消息发送成功。',
            ),
        ),
        responses=responses,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    files, archive = write_request_files(document, args.output.with_suffix(''))
    print(f'Exported {len(files)} separate JSON files, packaged as {archive}')
    print(f'Exported {len(responses)} complete responses to {args.output}')
    for record in responses:
        print(f'{record["status_code"]} {record["request"]["method"]} {record["request"]["path"]}')


if __name__ == '__main__':
    main()
