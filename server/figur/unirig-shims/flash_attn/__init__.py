"""CPU stand-in for flash_attn (StudioPortal on bigki): MHA (modules.mha) and the varlen packed-QKV attention used by PTv3."""
import torch
import torch.nn.functional as F


def flash_attn_varlen_qkvpacked_func(qkv, cu_seqlens, max_seqlen=None, dropout_p=0.0, softmax_scale=None, causal=False, **_):
    """qkv: (total, 3, heads, dim), cu_seqlens: (batch+1,) int -> (total, heads, dim); plain softmax attention per segment."""
    out = torch.empty(qkv.shape[0], qkv.shape[2], qkv.shape[3], dtype=qkv.dtype, device=qkv.device)
    bounds = cu_seqlens.tolist()
    for start, end in zip(bounds[:-1], bounds[1:]):
        if end <= start:
            continue
        q, k, v = qkv[start:end].unbind(1)               # (n, heads, dim)
        q, k, v = (t.transpose(0, 1).unsqueeze(0) for t in (q, k, v))
        o = F.scaled_dot_product_attention(q.float(), k.float(), v.float(), is_causal=causal, scale=softmax_scale)
        out[start:end] = o.squeeze(0).transpose(0, 1).to(qkv.dtype)
    return out
