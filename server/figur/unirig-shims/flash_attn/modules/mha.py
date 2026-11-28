"""Plain PyTorch stand-in for flash_attn.modules.mha.MHA (cross attention, non-causal) with the same parameter names
(Wq, Wkv, out_proj) so UniRig's skin checkpoint loads on CPU. Written for StudioPortal on bigki (gfx906 has no flash_attn)."""
import torch
import torch.nn as nn
import torch.nn.functional as F


class MHA(nn.Module):
    def __init__(self, embed_dim, num_heads, cross_attn=False, qkv_proj_bias=True, out_proj_bias=True, causal=False, **_):
        super().__init__()
        assert embed_dim % num_heads == 0
        self.embed_dim, self.num_heads, self.head_dim = embed_dim, num_heads, embed_dim // num_heads
        self.cross_attn, self.causal = cross_attn, causal
        if cross_attn:
            self.Wq = nn.Linear(embed_dim, embed_dim, bias=qkv_proj_bias)
            self.Wkv = nn.Linear(embed_dim, 2 * embed_dim, bias=qkv_proj_bias)
        else:
            self.Wqkv = nn.Linear(embed_dim, 3 * embed_dim, bias=qkv_proj_bias)
        self.out_proj = nn.Linear(embed_dim, embed_dim, bias=out_proj_bias)

    def forward(self, x, x_kv=None, key_padding_mask=None, **_):
        b, s, _d = x.shape
        h, d = self.num_heads, self.head_dim
        if self.cross_attn:
            kv_in = x if x_kv is None else x_kv
            q = self.Wq(x).view(b, s, h, d)
            kv = self.Wkv(kv_in).view(b, kv_in.shape[1], 2, h, d)
            k, v = kv.unbind(2)
        else:
            q, k, v = self.Wqkv(x).view(b, s, 3, h, d).unbind(2)
        mask = None
        if key_padding_mask is not None:
            mask = key_padding_mask[:, None, None, :].to(torch.bool)
        out = F.scaled_dot_product_attention(q.transpose(1, 2), k.transpose(1, 2), v.transpose(1, 2), attn_mask=mask, is_causal=self.causal)
        return self.out_proj(out.transpose(1, 2).reshape(b, s, h * d))
