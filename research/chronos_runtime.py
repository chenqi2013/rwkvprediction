import json
import math
import time
from importlib.metadata import version
from pathlib import Path


PAST_COVARIATES = ('open', 'high', 'low', 'volume', 'amount')
VARIANTS = ('Chronos-2-close', 'Chronos-2-ohlcv')


def chronos_task(case, covariates=False):
    import numpy as np
    history = case['history']
    task = {'target': np.array([row['close'] for row in history], dtype=np.float32)}
    if covariates:
        task['past_covariates'] = {
            field: np.array([row[field] for row in history], dtype=np.float32)
            for field in PAST_COVARIATES}
    return task


class ChronosRuntime:
    def __init__(self, name, device):
        import torch
        from chronos import Chronos2Pipeline
        from huggingface_hub import snapshot_download
        pin = json.loads(Path(__file__).with_name('model_pins.json').read_text())['Chronos-2']
        if version('chronos-forecasting') != pin['package_version']:
            raise ValueError('Chronos推理包版本与model_pins.json不一致')
        torch.set_num_threads(4)
        started = time.perf_counter()
        snapshot = snapshot_download(pin['repo'], revision=pin['revision'],
                                     allow_patterns=['config.json', 'model.safetensors'])
        self.pipeline = Chronos2Pipeline.from_pretrained(snapshot, device_map=device, torch_dtype=torch.float32)
        self.pipeline.model.eval()
        self.parameter_count = sum(parameter.numel() for parameter in self.pipeline.model.parameters())
        self.load_ms = round((time.perf_counter() - started) * 1000)
        self.covariates = name == 'Chronos-2-ohlcv'

    def predict(self, case, seed):
        import torch
        torch.manual_seed(seed)
        with torch.inference_mode():
            quantiles, _ = self.pipeline.predict_quantiles(
                [chronos_task(case, self.covariates)], prediction_length=60,
                quantile_levels=[0.5], context_length=61, cross_learning=False, batch_size=8)
        if len(quantiles) != 1 or tuple(quantiles[0].shape) != (1, 60, 1):
            raise ValueError('Chronos返回的分位数形状不合法')
        values = quantiles[0][0, :, 0].tolist()
        if any(not math.isfinite(value) or value <= 0 for value in values):
            raise ValueError('Chronos返回非法价格')
        last = float(case['history'][-1]['close'])
        return {str(horizon): (values[horizon - 1] / last - 1) * 100 for horizon in (5, 20, 60)}
