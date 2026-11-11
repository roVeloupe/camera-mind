#!/usr/bin/env python3
"""
本地 mock：模拟支持 thinking + 纯 JSON 的 OpenAI 兼容多模态接口。
用途：不烧 token 也能联调流式解析、参数落地、渲染链。

运行：
    python3 server/mock_server.py --port 8787
App 里 Base URL 填 http://<你的电脑IP>:8787/v1
"""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

THINKING = """画面里主体是逆光的窗边人像，右上方有约 12% 的高光溢出，暗部占了三分之一。
光源是下午四点的斜射日光，色温偏暖，估计在 4800K 上下。
意图应该是安静、带一点电影感的日常记录，不适合拉高对比，会把窗外的层次压死。
先压高光把窗外细节救回来，再提暗部让人脸有呼吸感，整体对比稍微收一点。
色彩上把暗部往青色推一点，高光保持暖调，形成冷暖分离，这是最有电影味的做法。
肤色需要单独处理：橙色饱和度降一点、明度提一点，避免提亮之后发黄。
清晰度对人像要负值，皮肤才不扎。颗粒给一点点，掩盖手机传感器的数码感。
"""

RESULT = {
    "capture": {
        "lens": "wide", "zoom": 1.0, "iso": 64, "shutterSeconds": 0.004,
        "exposureMode": "manual", "exposureBias": -0.3,
        "focusMode": "locked", "lensPosition": 0.42,
        "whiteBalanceMode": "locked", "temperature": 5000, "tint": 4,
        "torch": 0, "hdr": True, "stabilization": "standard", "aspect": "4:3"
    },
    "grade": {
        "exposureEV": 0.15, "brightness": 0.02, "contrast": -0.08,
        "highlights": -0.55, "shadows": 0.38, "blacks": -0.06, "whites": 0.04,
        "gamma": 1.02, "clarity": -0.12, "texture": -0.04, "dehaze": 0.08,
        "fade": 0.14, "curveShadows": 0.05, "curveMidtones": 0.0, "curveHighlights": -0.05,
        "temperature": -6, "tint": 2, "vibrance": 0.18, "saturation": -0.04,
        "hueShift": 0, "monochromeMix": 0,
        "splitShadowHue": 200, "splitShadowSat": 0.18,
        "splitHighlightHue": 40, "splitHighlightSat": 0.12,
        "hsl": [
            {"center": 0, "hue": 0, "saturation": -0.08, "luminance": 0.05},
            {"center": 30, "hue": -2, "saturation": -0.15, "luminance": 0.10},
            {"center": 60, "hue": 0, "saturation": -0.05, "luminance": 0.02},
            {"center": 120, "hue": 0, "saturation": 0.02, "luminance": 0.0},
            {"center": 180, "hue": 0, "saturation": 0.05, "luminance": 0.0},
            {"center": 240, "hue": 0, "saturation": 0.08, "luminance": -0.02},
            {"center": 300, "hue": 0, "saturation": 0.03, "luminance": 0.0},
            {"center": 330, "hue": 0, "saturation": -0.05, "luminance": 0.02}
        ],
        "sharpness": 0.18, "noiseReduction": 0.32, "noiseReductionDetail": 0.6,
        "grain": 0.12, "grainSize": 0.45,
        "vignette": -0.22, "vignetteFeather": 0.6, "bloom": 0.06,
        "halation": 0.1, "chromaticAberration": 0,
        "straightenAngle": 0, "cropZoom": 1.0,
        "perspectiveVertical": 0, "perspectiveHorizontal": 0, "rotate90": 0,
        "style": "cinematic", "styleStrength": 0.65
    },
    "rationale": {
        "highlights": "窗外高光溢出约 12%，压 -0.55 可换回玻璃上的层次",
        "shadows": "暗部占比大，提 0.38 让人脸和衣物有呼吸感",
        "contrast": "整体对比降一点，避免逆光场景过硬",
        "splitShadowHue": "暗部偏青 200°，与暖高光形成冷暖分离",
        "clarity": "人像皮肤不宜加清晰度，给 -0.12 更柔",
        "vibrance": "用自然饱和度提气色，避免整体饱和过高",
        "grain": "0.12 的细颗粒可以掩盖手机数码感",
        "iso": "锁定 ISO 64 保证动态范围，快门 1/250 手持安全"
    },
    "confidence": 0.82,
    "warnings": ["手持 1/250s 在弱光下可能欠曝，建议靠墙稳定", "锁定对焦后主体移动需重新对焦"]
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        body = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        # 1) thinking 增量
        for i in range(0, len(THINKING), 18):
            self._sse({"reasoning_content": THINKING[i:i + 18]})
            time.sleep(0.02)

        # 2) 正文：纯 JSON，分块吐出，故意在字符串中间切断，验证补全逻辑
        text = json.dumps(RESULT, ensure_ascii=False, indent=2)
        for i in range(0, len(text), 24):
            self._sse({"content": text[i:i + 24]})
            time.sleep(0.02)

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def _sse(self, delta):
        chunk = {"id": "mock", "object": "chat.completion.chunk",
                 "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
        data = "data: " + json.dumps(chunk, ensure_ascii=False) + "\n\n"
        self.wfile.write(data.encode("utf-8"))
        self.wfile.flush()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    args = ap.parse_args()
    srv = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    print(f"mock server on http://0.0.0.0:{args.port}/v1")
    srv.serve_forever()
