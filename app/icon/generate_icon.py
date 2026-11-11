#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""NX游戏库 · app 图标生成器 v2(Mac 扁平美学)

设计语言:Apple 式克制——单一主体、几何化、无描边装饰、无霓虹光。
  - 底:    炭灰垂直渐变 #3C3C3E→#28282A,大圆角(22.5%),四角透明
  - 主体:  正视 Switch 造型的扁平掌机(居中,宽 = 画布 66%):
             · 机身 = 深黑圆角矩形 #1B1B1D
             · 左 Joy-Con #E4484E / 右 Joy-Con #3E8EED(外缘大圆角,纯色块)
             · 摇杆按实机布局:左上、右下,深色小圆(点到为止的"游戏机"暗示)
             · 屏幕内白色播放三角(85% 不透明,微圆角,光学居中)
  - 阴影:  机身下方柔和椭圆投影(黑 35%,高斯模糊)——Mac 图标的"落地感"
用法:  .venv/bin/python generate_icon.py
输出:  master_1024.png · AppIcon.iconset/* · AppIcon.icns(本目录)
"""
import os
import shutil
import subprocess

from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 4
W = S * SS

# 底
BG_TOP = (0x3C, 0x3C, 0x3E)
BG_BOT = (0x28, 0x28, 0x2A)
CORNER_R = 0.225 * S * SS

# 掌机几何(基准 1024,绘制时乘 SS)
DEV_W = 0.66 * S            # 机身总宽(含 Joy-Con)
DEV_H = DEV_W / 2.28        # 实机比例约 2.3:1,略收一点更挺
JOY_W = DEV_W * 0.145       # 单侧 Joy-Con 宽
BODY_R = DEV_H * 0.17       # 机身圆角(外缘更圆润,贴近实机)
SCREEN_INSET_Y = DEV_H * 0.075
SCREEN_INSET_X = DEV_H * 0.075
SCREEN_R = DEV_H * 0.05
BODY_COLOR = (0x1B, 0x1B, 0x1D)
SCREEN_COLOR = (0x14, 0x14, 0x16)
RED = (0xE4, 0x48, 0x4E)
BLUE = (0x3E, 0x8E, 0xED)
STICK = (0x23, 0x23, 0x25)
WHITE = (255, 255, 255)
SHADOW = (0, 0, 0)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rounded(dr, box, r, fill):
    dr.rounded_rectangle(box, radius=int(r), fill=fill)


def triangle(dr, cx, cy, h, fill):
    """干净的锐角播放三角(扁平风:不加顶点圆球,4x 超采样保证边缘顺滑)"""
    w = h * 0.88
    x0, x1 = cx - w * 0.42, cx + w * 0.58
    dr.polygon([(x0, cy - h / 2), (x1, cy), (x0, cy + h / 2)], fill=fill)


def build():
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))

    # 背景渐变(满铺圆角)
    bg = Image.new("RGB", (W, W))
    d = ImageDraw.Draw(bg)
    for y in range(W):
        d.line([(0, y), (W, y)], fill=lerp(BG_TOP, BG_BOT, y / (W - 1)))
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, W - 1, W - 1], radius=int(CORNER_R), fill=255)
    img.paste(bg, (0, 0), mask)

    d = ImageDraw.Draw(img)
    cx, cy = W / 2, W / 2
    dev_w, dev_h = DEV_W * SS, DEV_H * SS
    x0, y0 = cx - dev_w / 2, cy - dev_h / 2
    x1, y1 = cx + dev_w / 2, cy + dev_h / 2
    joy_w = JOY_W * SS
    body_r = BODY_R * SS

    # 投影
    sh = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ds = ImageDraw.Draw(sh)
    ds.ellipse([x0 + dev_w * 0.04, y1 + dev_h * 0.10,
                x1 - dev_w * 0.04, y1 + dev_h * 0.34],
               fill=(*SHADOW, 90))
    sh = sh.filter(ImageFilter.GaussianBlur(dev_h * 0.075))
    img = Image.alpha_composite(img, sh)
    d = ImageDraw.Draw(img)

    # 机身(整块深色圆角矩形,垫底)
    rounded(d, [x0, y0, x1, y1], body_r, BODY_COLOR)

    # Joy-Con:外缘大圆角 + 内侧直角(全高矩形补角,叠加同色即得"外圆内方")
    rounded(d, [x0, y0, x0 + joy_w, y1], body_r, RED)
    d.rectangle([x0 + joy_w - body_r, y0, x0 + joy_w, y1], fill=RED)
    rounded(d, [x1 - joy_w, y0, x1, y1], body_r, BLUE)
    d.rectangle([x1 - joy_w, y0, x1 - joy_w + body_r, y1], fill=BLUE)

    # 摇杆:实机布局(左上、右下)
    stick_r = dev_h * 0.055
    sx_l = x0 + joy_w / 2
    sx_r = x1 - joy_w / 2
    d.ellipse([sx_l - stick_r, y0 + dev_h * 0.28 - stick_r,
               sx_l + stick_r, y0 + dev_h * 0.28 + stick_r], fill=STICK)
    d.ellipse([sx_r - stick_r, y1 - dev_h * 0.28 - stick_r,
               sx_r + stick_r, y1 - dev_h * 0.28 + stick_r], fill=STICK)

    # 屏幕
    s0 = [x0 + joy_w + SCREEN_INSET_X * SS, y0 + SCREEN_INSET_Y * SS,
          x1 - joy_w - SCREEN_INSET_X * SS, y1 - SCREEN_INSET_Y * SS]
    rounded(d, s0, SCREEN_R * SS, SCREEN_COLOR)

    # 播放三角(屏幕上,光学居中)
    scx = (s0[0] + s0[2]) / 2 + (s0[2] - s0[0]) * 0.02
    scy = (s0[1] + s0[3]) / 2
    triangle(d, scx, scy, (s0[3] - s0[1]) * 0.36, (*WHITE, 217))

    return img.resize((S, S), Image.LANCZOS)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    img = build()
    img.save(os.path.join(here, "master_1024.png"))

    iconset = os.path.join(here, "AppIcon.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    sizes = [(16, 32), (32, 64), (128, 256), (256, 512), (512, 1024)]
    for px, two_x in sizes:
        img.resize((px, px), Image.LANCZOS).save(
            os.path.join(iconset, f"icon_{px}x{px}.png"))
        img.resize((two_x, two_x), Image.LANCZOS).save(
            os.path.join(iconset, f"icon_{px}x{px}@2x.png"))

    icns = os.path.join(here, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print("done:", icns)


if __name__ == "__main__":
    main()
