"""Experimental CPU reference for the pinned A-share RWKV7 forecast checkpoint.

Implements its numerical feature projection, RWKV7 recurrence and quantile head
with plain PyTorch. No Transformers fork, remote code, CUDA or HTTP service.
BF16 edges are emulated in FP32; CUDA parity is NOT yet validated. This is a
porting prototype, not the production Flutter runtime. See RWKV7-NOTICES.md.
"""

import json
import math
from pathlib import Path

import torch
import torch.nn.functional as F
from safetensors.torch import load_file


def wkv_recurrence(r, logits, k, v, a, b):
    """Independent [B,T,H,D] windows; FP32 state indexed [B,H,key,value]."""
    state = r.new_zeros(r.shape[0], r.shape[2], r.shape[3], r.shape[3])
    decay = torch.exp(-math.exp(-0.5) * torch.sigmoid(logits))
    outputs = []
    for t in range(r.shape[1]):
        dot = (state * a[:, t, :, :, None]).sum(dim=-2)
        state = (
            decay[:, t, :, :, None] * state
            + b[:, t, :, :, None] * dot[:, :, None, :]
            + k[:, t, :, :, None] * v[:, t, :, None, :]
        )
        outputs.append((state * r[:, t, :, :, None]).sum(dim=-2))
    return torch.stack(outputs, dim=1)


class RWKV7CPU:
    """Load only previously hash-verified safetensors; always executes on CPU."""

    def __init__(self, directory: Path):
        config = json.loads((directory / 'config.json').read_text())
        self.config = config['backbone_config']
        if (config['model_type'], self.config['architecture_version']) != ('rwkv7_forecast', 'rwkv7'):
            raise ValueError('Expected the pinned RWKV7 quantile forecasting model')
        index = json.loads((directory / 'model.safetensors.index.json').read_text())['weight_map']
        tensors = {}
        for filename in sorted(set(index.values())):
            # Reject index paths before touching the filesystem.
            if Path(filename).name != filename:
                raise ValueError('Invalid weight shard path')
            tensors.update(load_file(directory / filename, device='cpu'))
        if set(tensors) != set(index):
            raise ValueError('Weight index and checkpoint tensors differ')
        self.weights = {name: value.float() for name, value in tensors.items()}
        self.heads = self.config['num_attention_heads']
        self.dim = self.config['head_size']
        self.channels = self.config['hidden_size']

    @staticmethod
    def rounded(value):
        return value.bfloat16().float()

    def norm(self, x, prefix, eps):
        return self.rounded(F.layer_norm(
            x, (self.channels,), self.weights[prefix + '.weight'],
            self.weights[prefix + '.bias'], eps,
        ))

    def linear(self, x, prefix):
        return self.rounded(F.linear(x, self.weights[prefix + '.weight'], self.weights.get(prefix + '.bias')))

    def mix(self, x, parameter):
        previous = F.pad(x[:, :-1], (0, 0, 1, 0))
        return self.rounded(x + (previous - x) * parameter)

    @torch.inference_mode()
    def predict(self, features):
        shape = (self.config['context_length'], self.config['forecast_input_size'])
        if features.ndim != 3 or tuple(features.shape[1:]) != shape or features.shape[0] < 1:
            raise ValueError(f'Expected [batch,{shape[0]},{shape[1]}]')
        if features.device.type != 'cpu' or not torch.isfinite(features).all():
            raise ValueError('Features must be finite CPU tensors')
        w = self.weights
        eps = self.config['layer_norm_epsilon']
        x = (features.float() - w['feature_mean']) / w['feature_std']
        x = self.linear(self.rounded(x), 'input_projection')
        x = self.norm(x, 'hf.embedding_norm', eps)
        first_value = None
        for layer in range(self.config['num_hidden_layers']):
            p = f'hf.layers.{layer}.'
            att = p + 'linear_attn.'
            z = self.norm(x, p + 'input_layernorm', eps)
            mixed = {key: self.mix(z, w[att + 'x_' + key]) for key in 'rwkvag'}
            r = self.linear(mixed['r'], att + 'r_proj')
            k = self.linear(mixed['k'], att + 'k_proj')
            v = self.linear(mixed['v'], att + 'v_proj')

            def lowrank(key, first_activation=None, bias=None, final_activation=None):
                y = self.rounded(mixed[key] @ w[att + key + '1'])
                if first_activation:
                    y = self.rounded(first_activation(y))
                y = self.rounded(y @ w[att + key + '2'])
                if bias:
                    y = y + w[att + bias]
                if final_activation:
                    y = final_activation(y)
                return self.rounded(y)

            logits = lowrank('w', torch.tanh, 'w0')
            rate = lowrank('a', bias='a0', final_activation=torch.sigmoid)
            gate = lowrank('g', torch.sigmoid)
            if first_value is None:
                first_value = v
            else:
                blend = torch.sigmoid(w[att + 'v0'] + lowrank('v'))
                v = self.rounded(v + (first_value - v) * blend)
            head_shape = (*k.shape[:2], self.heads, self.dim)
            direction = F.normalize((k * w[att + 'k_k']).reshape(head_shape), dim=-1, eps=1e-12)
            a = self.rounded(-direction)
            b = self.rounded(direction * rate.reshape(head_shape))
            k = self.rounded(k * (1 + (rate - 1) * w[att + 'k_a']))
            r, k, v, logits = (t.reshape(head_shape) for t in (r, k, v, logits))
            recurrent = self.rounded(wkv_recurrence(r, logits, k, v, a, b))
            centered = recurrent - recurrent.mean(dim=-1, keepdim=True)
            normalized = centered * torch.rsqrt(centered.square().mean(dim=-1, keepdim=True) + self.config['group_norm_epsilon'])
            normalized = normalized.flatten(-2) * w[att + 'g_norm.weight'] + w[att + 'g_norm.bias']
            residual = (r * k * w[att + 'r_k']).sum(dim=-1, keepdim=True) * v
            readout = self.rounded((normalized + residual.flatten(-2)) * gate)
            x = self.rounded(x + self.linear(readout, att + 'o_proj'))
            z = self.norm(x, p + 'post_attention_layernorm', eps)
            z = self.mix(z, w[p + 'mlp.x_k'])
            z = self.rounded(torch.relu(self.linear(z, p + 'mlp.key')).square())
            x = self.rounded(x + self.linear(z, p + 'mlp.value'))
        hidden = self.norm(x, 'hf.norm', eps)[:, -1]
        raw = F.linear(hidden, w['output_projection.weight'], w['output_projection.bias'])
        raw = raw.reshape(-1, self.config['forecast_horizon'], len(self.config['forecast_quantiles']))
        if not torch.isfinite(raw).all():
            raise ValueError('Non-finite model output')
        return raw
