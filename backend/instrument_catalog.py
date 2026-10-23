"""Searchable AKShare instrument metadata, cached separately from quotes."""
import json
import logging
import re
import threading
import time
from pathlib import Path

KINDS = {'ETF': 'etf', '指数': 'index', '股票': 'stock'}
MARKETS = {'sh': '上交所', 'sz': '深交所', 'bj': '北交所'}


class CatalogUnavailable(Exception):
    pass


def instrument(symbol, name, kind, market=None):
    symbol = str(symbol).lower().strip()
    if symbol[:2] in MARKETS:
        market, symbol = symbol[:2], symbol[2:]
    symbol = symbol.zfill(6)
    if market is None:
        if kind == '指数':
            market = 'sz' if symbol.startswith('399') else 'sh'
        else:
            market = 'sh' if symbol.startswith(('5', '6')) else 'bj' if symbol.startswith(('4', '8', '9')) else 'sz'
    if not re.fullmatch(r'\d{6}', symbol) or market not in MARKETS or kind not in KINDS or not str(name).strip():
        raise ValueError('Invalid instrument metadata')
    return dict(id=f'{market}-{KINDS[kind]}-{symbol}', symbol=symbol, name=str(name).strip(),
                kind=kind, market=market, subtitle=MARKETS[market], currency='CNY')


def load_instruments(kind):
    import akshare as ak
    if kind == '股票':
        ak.stock_info_a_code_name.cache_clear()
        frame = ak.stock_info_a_code_name()
        return [instrument(row['code'], row['name'], kind) for row in frame.to_dict('records')]
    if kind == 'ETF':
        frame = ak.fund_etf_category_sina(symbol='ETF基金')
        return [instrument(row['代码'], row['名称'], kind) for row in frame.to_dict('records')]
    frame = ak.index_stock_info()
    return [instrument(row['index_code'], row['display_name'], kind) for row in frame.to_dict('records')]


class InstrumentCatalog:
    def __init__(self, seeds, loader=None, cache_dir=None, ttl=86400, timeout=20):
        self.loader = loader or load_instruments
        self.cache_dir = Path(cache_dir) if cache_dir else None
        self.ttl = ttl
        self.timeout = timeout
        self.lock = threading.Lock()
        self.entries = {kind: dict(items={}, updated=0, event=None, error=None, retry_after=0) for kind in KINDS}
        self.seeds = {item['id']: item for item in seeds}
        if self.cache_dir:
            for kind, slug in KINDS.items():
                try:
                    saved = json.loads((self.cache_dir / f'{slug}.json').read_text())
                    items = [instrument(row['symbol'], row['name'], kind, row['market']) for row in saved['items']]
                    if items:
                        self.entries[kind].update(items={item['id']: item for item in items}, updated=saved['updated'])
                except (OSError, ValueError, KeyError, TypeError):
                    pass

    def _refresh(self, kind, event):
        try:
            items = self.loader(kind)
            if not items:
                raise ValueError('Empty instrument list')
            items = [instrument(row['symbol'], row['name'], kind, row['market']) for row in items]
            updated = time.time()
            with self.lock:
                self.entries[kind].update(items={item['id']: item for item in items}, updated=updated, error=None)
            if self.cache_dir:
                try:
                    self.cache_dir.mkdir(parents=True, exist_ok=True)
                    destination = self.cache_dir / f'{KINDS[kind]}.json'
                    temporary = destination.with_suffix('.tmp')
                    temporary.write_text(json.dumps(dict(items=items, updated=updated), ensure_ascii=False))
                    temporary.replace(destination)
                except OSError as error:
                    logging.warning('Could not persist instrument catalog: %s', error)
        except Exception as error:
            logging.warning('Instrument catalog refresh failed for %s: %s', kind, error)
            with self.lock:
                self.entries[kind].update(error=str(error), retry_after=time.time() + 60)
        finally:
            event.set()

    def _start(self, kind):
        with self.lock:
            entry = self.entries[kind]
            if time.time() - entry['updated'] < self.ttl or time.time() < entry['retry_after']:
                return None
            event = entry['event']
            if event is None or event.is_set():
                event = threading.Event()
                entry['event'] = event
                threading.Thread(target=self._refresh, args=(kind, event), daemon=True).start()
            return event

    def search(self, query='', kind=None, limit=50, offset=0):
        if kind is not None and kind not in KINDS:
            raise ValueError('kind must be ETF, 指数 or 股票')
        kinds = [kind] if kind else list(KINDS)
        events = [self._start(category) for category in kinds]
        deadline = time.monotonic() + self.timeout
        for event in events:
            if event is not None:
                event.wait(max(0, deadline - time.monotonic()))
        with self.lock:
            items = dict(self.seeds)
            warnings = []
            for category in kinds:
                entry = self.entries[category]
                items.update(entry['items'])
                if time.time() - entry['updated'] >= self.ttl:
                    warnings.append(f'{category}名单暂未更新，当前仅搜索已缓存名单，请稍后重试。')
            if all(not self.entries[category]['items'] for category in kinds):
                raise CatalogUnavailable('标的名单获取失败或仍在加载，请稍后重试。')
        query = query.strip().casefold()
        result = [item for item in items.values() if item['kind'] in kinds and
                  (not query or query in item['name'].casefold() or query in item['symbol'] or
                   query in item['market'] + item['symbol'] or query == item['id'])]
        result.sort(key=lambda item: (item['symbol'] != query, not item['name'].casefold().startswith(query), item['symbol'], item['id']))
        return dict(items=result[offset:offset + limit], total=len(result), limit=limit, offset=offset,
                    has_more=offset + limit < len(result), warnings=warnings)

    def resolve(self, identity):
        if identity in self.seeds:
            return self.seeds[identity]
        with self.lock:
            for entry in self.entries.values():
                if identity in entry['items']:
                    return entry['items'][identity]
        match = re.fullmatch(r'(sh|sz|bj)-(etf|index|stock)-(\d{6})', identity)
        if not match:
            raise KeyError(identity)
        kind = next(kind for kind, slug in KINDS.items() if slug == match[2])
        result = self.search(match[3], kind)
        for item in result['items']:
            if item['id'] == identity:
                return item
        raise KeyError(identity)
