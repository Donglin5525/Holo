// 截图识别记账 · 评测样张生成器
// 用法: swift tools/render_corpus.swift corpus   （在 docs/holoai-audit/vision-eval/ 下执行）
// 生成 24 张合成样张，期望结果见 corpus/manifest.json，两者数字必须保持一致。

import AppKit
import CoreImage

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "corpus"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// MARK: - 基础绘制

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
}

func text(_ s: String, _ rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
          mono: Bool = true, color c: NSColor = .black, align: NSTextAlignment = .left) {
    let p = NSMutableParagraphStyle()
    p.alignment = align
    let f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                 : NSFont.systemFont(ofSize: size, weight: weight)
    (s as NSString).draw(in: rect, withAttributes: [
        .font: f, .foregroundColor: c, .paragraphStyle: p
    ])
}

func dashedLine(_ y: CGFloat, _ w: CGFloat) {
    NSColor.black.setStroke()
    let p = NSBezierPath()
    p.lineWidth = 1.5
    p.setLineDash([6, 4], count: 2, phase: 0)
    p.move(to: NSPoint(x: 50, y: y))
    p.line(to: NSPoint(x: w - 50, y: y))
    p.stroke()
}

func render(_ size: NSSize, bg: NSColor, _ draw: () -> Void) -> NSImage {
    let img = NSImage(size: size)
    img.lockFocus()
    bg.setFill()
    NSRect(origin: .zero, size: size).fill()
    draw()
    img.unlockFocus()
    return img
}

func save(_ img: NSImage, _ name: String) {
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
    let jpgName = name.replacingOccurrences(of: ".png", with: ".jpg")
    try! jpeg.write(to: URL(fileURLWithPath: outDir + "/" + jpgName))
    print("✓ \(jpgName)")
}

func blurred(_ image: NSImage, radius: Double) -> NSImage {
    guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return image }
    let f = CIFilter(name: "CIGaussianBlur")!
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(radius, forKey: kCIInputRadiusKey)
    guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: ci.extent) else { return image }
    let result = NSImage(size: image.size)
    result.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: image.size).fill()
    NSImage(cgImage: cg, size: image.size).draw(in: NSRect(origin: .zero, size: image.size))
    result.unlockFocus()
    return result
}

// MARK: - 小票 / 发票

func receipt(name: String, addr: String, invoiceNo: String? = nil, dateLine: String,
             items: [(String, Double)], payLabel: String,
             footer: String = "谢谢惠顾", faint: Bool = false, stamp: Bool = false) -> NSImage {
    let w: CGFloat = 760
    let rowH: CGFloat = 46
    let h: CGFloat = 380 + CGFloat(items.count) * rowH + 320
    let img = render(NSSize(width: w, height: h), bg: .white) {
        var y = h - 80
        if let inv = invoiceNo {
            text("电子发票（普通发票）", NSRect(x: 40, y: y - 44, width: w - 80, height: 48),
                 size: 32, weight: .bold, mono: false, align: .center)
            y -= 66
            text("发票号码：\(inv)", NSRect(x: 60, y: y - 26, width: w - 120, height: 30),
                 size: 22, mono: false, color: .darkGray)
            y -= 46
        }
        text(name, NSRect(x: 40, y: y - 44, width: w - 80, height: 48),
             size: invoiceNo == nil ? 38 : 30, weight: .bold, mono: false, align: .center)
        y -= 72
        text(addr, NSRect(x: 40, y: y - 26, width: w - 80, height: 30),
             size: 21, mono: false, color: .darkGray, align: .center)
        y -= 46
        dashedLine(y, w)
        y -= 18
        text("项目", NSRect(x: 60, y: y - 30, width: 300, height: 32), size: 22, weight: .semibold, color: .darkGray)
        text("金额", NSRect(x: w - 260, y: y - 30, width: 200, height: 32), size: 22, weight: .semibold, color: .darkGray, align: .right)
        y -= 42
        for (iname, iamount) in items {
            text(iname, NSRect(x: 60, y: y - 30, width: w - 340, height: 32), size: 24)
            text(String(format: "¥%.2f", iamount), NSRect(x: w - 260, y: y - 30, width: 200, height: 32), size: 24, align: .right)
            y -= rowH
        }
        y -= 4
        dashedLine(y, w)
        y -= 54
        text("合计", NSRect(x: 60, y: y - 34, width: 200, height: 36), size: 27, weight: .bold, mono: false)
        let total = items.reduce(0) { $0 + $1.1 }
        text(String(format: "¥%.2f", total), NSRect(x: w - 300, y: y - 36, width: 240, height: 40), size: 30, weight: .bold, align: .right)
        y -= 56
        text(payLabel, NSRect(x: 60, y: y - 28, width: w - 120, height: 32), size: 23, mono: false, color: .darkGray)
        y -= 44
        text(dateLine, NSRect(x: 60, y: y - 24, width: w - 120, height: 28), size: 21, color: .darkGray)
        y -= 58
        text(footer, NSRect(x: 40, y: y - 30, width: w - 80, height: 32), size: 22, mono: false, color: .gray, align: .center)
        var bx: CGFloat = 90
        var rnd = SystemRandomNumberGenerator()
        while bx < w - 110 {
            let bw = CGFloat.random(in: 2...7, using: &rnd)
            NSColor.black.setFill()
            NSRect(x: bx, y: 46, width: bw, height: 64).fill()
            bx += bw + CGFloat.random(in: 2...6, using: &rnd)
        }
        if stamp {
            let cx = w - 180, cy = h * 0.52
            color(0xCC3126).setStroke()
            let oval = NSBezierPath(ovalIn: NSRect(x: cx - 88, y: cy - 88, width: 176, height: 176))
            oval.lineWidth = 4
            oval.stroke()
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: cx, yBy: cy)
            t.rotate(byDegrees: -14)
            t.concat()
            text("发票专用章", NSRect(x: -84, y: -18, width: 168, height: 36),
                 size: 26, weight: .bold, mono: false, color: color(0xCC3126, 0.9), align: .center)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    return faint ? blurred(img, radius: 3.2) : img
}

// MARK: - App 截图

func phone(app: String, tint: UInt32, nav: String, big: String? = nil, bigColor: UInt32 = 0x222222,
           cards: [[(String, String)]], statusText: String? = nil, statusColor: UInt32 = 0x0A8F4E) -> NSImage {
    let w: CGFloat = 900, h: CGFloat = 1560
    return render(NSSize(width: w, height: h), bg: color(0xF2F3F5)) {
        color(0x1A1A1A).setFill()
        text("22:41", NSRect(x: 44, y: h - 64, width: 200, height: 34), size: 27, weight: .semibold, mono: false)
        text("5G 100%", NSRect(x: w - 264, y: h - 64, width: 220, height: 34), size: 25, mono: false, align: .right)
        color(tint).setFill()
        NSRect(x: 0, y: h - 208, width: w, height: 140).fill()
        text("\(app) · \(nav)", NSRect(x: 40, y: h - 194, width: w - 80, height: 46),
             size: 33, weight: .semibold, mono: false, color: .white, align: .center)
        var y = h - 252
        if let b = big {
            text(b, NSRect(x: 40, y: y - 86, width: w - 80, height: 94),
                 size: 66, weight: .bold, mono: false, color: color(bigColor), align: .center)
            y -= 124
        }
        for card in cards {
            let ch = CGFloat(card.count) * 68 + 40
            color(0xFFFFFF).setFill()
            NSBezierPath(roundedRect: NSRect(x: 36, y: y - ch, width: w - 72, height: ch), xRadius: 18, yRadius: 18).fill()
            var cy = y - 54
            for (k, v) in card {
                text(k, NSRect(x: 66, y: cy - 32, width: 300, height: 36), size: 26, mono: false, color: .gray)
                text(v, NSRect(x: w / 2 - 60, y: cy - 32, width: w - (w / 2 - 60) - 60, height: 36),
                     size: 26, weight: .medium, mono: false, align: .right)
                cy -= 68
            }
            y -= ch + 32
        }
        if let s = statusText {
            y -= 16
            text(s, NSRect(x: 40, y: y - 46, width: w - 80, height: 50),
                 size: 33, weight: .bold, mono: false, color: color(statusColor), align: .center)
        }
    }
}

// MARK: - 其他干扰图

func chatScreenshot() -> NSImage {
    let w: CGFloat = 900, h: CGFloat = 1100
    func bubbleAt(_ s: String, _ x: CGFloat, _ yTop: CGFloat, _ bw: CGFloat, mine: Bool) {
        let bh: CGFloat = 88
        let rect = NSRect(x: x, y: yTop - bh, width: bw, height: bh)
        (mine ? color(0x95EC69) : NSColor.white).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
        text(s, NSRect(x: rect.minX + 22, y: rect.midY - 18, width: bw - 44, height: 38),
             size: 28, mono: false)
    }
    return render(NSSize(width: w, height: h), bg: color(0xEDEDED)) {
        color(0xF7F7F7).setFill()
        NSRect(x: 0, y: h - 210, width: w, height: 140).fill()
        text("小美", NSRect(x: 40, y: h - 194, width: w - 80, height: 44),
             size: 34, weight: .semibold, mono: false, align: .center)
        bubbleAt("明天中午一起吃饭吗？", 40, h - 330, 430, mine: false)
        bubbleAt("好啊，去哪吃？", w - 40 - 330, h - 480, 330, mine: true)
        bubbleAt("公司楼下的面馆，12点见", 40, h - 630, 430, mine: false)
        bubbleAt("好，不见不散", w - 40 - 300, h - 760, 300, mine: true)
    }
}

func listNote() -> NSImage {
    let w: CGFloat = 820, h: CGFloat = 1000
    return render(NSSize(width: w, height: h), bg: color(0xF6F0DC)) {
        text("购物清单", NSRect(x: 40, y: h - 130, width: w - 80, height: 64),
             size: 46, weight: .bold, mono: false)
        var y = h - 260
        for r in ["牛奶", "鸡蛋", "洗衣液", "抽纸", "香蕉"] {
            color(0x404040).setStroke()
            let box = NSBezierPath(roundedRect: NSRect(x: 80, y: y - 38, width: 34, height: 34), xRadius: 6, yRadius: 6)
            box.lineWidth = 3
            box.stroke()
            text(r, NSRect(x: 140, y: y - 42, width: 420, height: 46), size: 33, mono: false)
            y -= 100
        }
    }
}

func plainTest() -> NSImage {
    let w: CGFloat = 900, h: CGFloat = 900
    return render(NSSize(width: w, height: h), bg: color(0x2B3A67)) {
        color(0x3E5C76).setFill()
        NSRect(x: 0, y: 0, width: w, height: h * 0.55).fill()
        text("HOLO 样张", NSRect(x: 40, y: h / 2 - 30, width: w - 80, height: 84),
             size: 56, weight: .bold, mono: false, color: .white, align: .center)
        text("TEST IMAGE · 非账单", NSRect(x: 40, y: h / 2 - 130, width: w - 80, height: 60),
             size: 34, mono: false, color: color(0xBFCBD9), align: .center)
    }
}

// MARK: - 生成全部 24 张（期望结果与 manifest.json 一一对应）

// —— 可记账：纸质小票/发票（10 张）——
save(receipt(name: "瑞幸咖啡 LUCKIN", addr: "星海广场店 0412", dateLine: "2026-08-28 12:35  单号 202608281235001",
             items: [("大杯生椰拿铁(热/标准糖)", 9.9), ("黄油可颂", 10.0)],
             payLabel: "微信支付  实收 ¥19.90"), "r01_luckin_wechat.png")

save(receipt(name: "盒马鲜生", addr: "星光大道店", dateLine: "2026-09-01 18:22  单号 202609011822888",
             items: [("有机菠菜 300g", 6.9), ("冷鲜牛奶 950ml", 12.5), ("土鸡蛋 10枚", 19.9),
                     ("黑猪五花肉 400g", 32.8), ("阳光玫瑰葡萄 500g", 26.5)],
             payLabel: "支付宝  实收 ¥98.60"), "r02_hema_alipay.png")

save(receipt(name: "滴滴出行", addr: "快车 · 东港广场 → 软件园", dateLine: "2026-08-30 09:12  单号 D202608300912",
             items: [("里程费 12.6公里(含时长费)", 23.5)],
             payLabel: "工商银行储蓄卡(尾号4321)  实付 ¥23.50", footer: "电子行程单"), "r03_didi_bank.png")

save(receipt(name: "全家 FAMILYMart", addr: "高新园区店", dateLine: "2026-09-02 08:05  单号 20260902080566",
             items: [("森林水 555ml", 2.0), ("金枪鱼三明治", 13.0)],
             payLabel: "微信支付  实收 ¥15.00"), "r04_family_wechat.png")

save(receipt(name: "海底捞火锅", addr: "万象城店 桌号 B12", dateLine: "2026-08-29 19:48  单号 202608291948123",
             items: [("招牌锅底", 78.0), ("捞派滑牛肉", 88.0), ("虾滑", 59.0), ("蔬菜拼盘", 46.0)],
             payLabel: "支付宝  实收 ¥271.00"), "r05_haidilao_alipay.png")

save(receipt(name: "屈臣氏 WATSONS", addr: "中央大道店", dateLine: "2026-08-27 15:40  单号 202608271540333",
             items: [("氨基酸洗面奶 150g", 39.9), ("三层抽纸 8包", 16.5)],
             payLabel: "现金支付  实收 ¥56.40"), "r08_watsons_cash.png")

save(receipt(name: "优衣库 UNIQLO", addr: "来福士店 · 退货退款凭证", dateLine: "2026-09-05 14:22  单号 RT202609051422",
             items: [("纯色圆领T恤(M)", 39.9)],
             payLabel: "退款将原路退回至微信支付", footer: "退货凭证请妥善保管"), "r09_refund_wechat.png")

save(receipt(name: "中国石化 SINOPEC", addr: "东快路加油站", dateLine: "2026-08-31 17:20  单号 202608311720456",
             items: [("92号汽油 40.56L", 350.0)],
             payLabel: "工商银行信用卡(尾号6688)  实付 ¥350.00", footer: "加油小票"), "r11_gas_bank.png")

save(receipt(name: "老百姓大药房", addr: "黄河路店", dateLine: "2026-09-06 10:11  单号 202609061011777",
             items: [("感冒灵颗粒 10袋", 15.8), ("维C泡腾片 20片", 29.9)],
             payLabel: "微信支付  实收 ¥45.70"), "r12_pharmacy_wechat.png")

save(receipt(name: "星巴克咖啡", addr: "大连来福士门店", invoiceNo: "24312000000123456",
             dateLine: "开票日期 2026-09-01",
             items: [("咖啡饮品", 35.0)],
             payLabel: "微信支付", footer: "此发票为电子发票", stamp: true), "r13_invoice_wechat.png")

save(receipt(name: "永和豆浆", addr: "解放路店", dateLine: "2026-09-06 07:55  单号 202609060755222",
             items: [("现磨豆浆(大)", 5.0), ("大油条", 7.0)],
             payLabel: "微信支付  实收 ¥12.00", faint: true), "r15_blur_wechat.png")

// —— 可记账：支付类截图（4 张，含一张两笔）——
save(phone(app: "京东", tint: 0xE1251B, nav: "订单详情",
           cards: [[("商品", "无线蓝牙耳机"), ("实付", "¥89.00"), ("支付方式", "微信支付"), ("付款时间", "2026-09-03 21:45")]],
           statusText: "已完成"), "r06_jd_order.png")

save(phone(app: "美团外卖", tint: 0xFFC300, nav: "订单详情",
           cards: [[("商家", "老乡鸡(青泥店)"), ("实付", "¥42.80 含配送费¥3.80"), ("支付方式", "支付宝"), ("付款时间", "2026-09-04 12:30")]],
           statusText: "已送达", statusColor: 0xE07800), "r07_meituan_alipay.png")

save(phone(app: "猫眼电影", tint: 0x00B96B, nav: "订单详情",
           cards: [[("影片", "流浪地球3(IMAX 2张)"), ("实付", "¥79.80"), ("支付方式", "微信支付"), ("付款时间", "2026-09-07 19:20")]],
           statusText: "已完成"), "r14_movie_wechat.png")

save(phone(app: "支付宝", tint: 0x1677FF, nav: "账单",
           cards: [[("商家", "桂林米粉(青泥店)"), ("金额", "¥8.00"), ("支付时间", "2026-09-06 08:32"), ("支付方式", "账户余额")],
                   [("商家", "鲜丰水果"), ("金额", "¥25.50"), ("支付时间", "2026-09-06 19:04"), ("支付方式", "账户余额")]]),
      "r10_alipay_bills.png")

// —— 必须拦截：资金流转 ——
save(phone(app: "微信", tint: 0x07C160, nav: "转账", big: "¥500.00",
           cards: [[("收款方", "张三"), ("转账时间", "2026-09-05 20:18"), ("转账说明", "周末聚餐AA")]],
           statusText: "朋友已收款"), "x01_wechat_transfer.png")

save(phone(app: "掌上生活", tint: 0xD5281F, nav: "信用卡还款", big: "¥2,000.00",
           cards: [[("还款卡号", "招商银行信用卡(尾号0000)"), ("还款时间", "2026-09-04 21:02"), ("还款方式", "储蓄卡(尾号6688)")]],
           statusText: "还款成功"), "x06_creditcard_repay.png")

// —— 必须拒识：其他 ——
save(phone(app: "支付宝", tint: 0x1677FF, nav: "余额宝", big: "¥12,345.67",
           cards: [[("昨日收益", "¥1.23"), ("七日年化", "1.89%"), ("累计收益", "¥1,203.45")]]),
      "x02_alipay_wealth.png")

save(phone(app: "拼多多", tint: 0xE02E24, nav: "订单详情",
           cards: [[("商品", "小米台灯 Pro"), ("订单金额", "¥129.00"), ("付款状态", "待付款")]],
           statusText: "等待付款", statusColor: 0xE07800), "x07_unpaid_order.png")

save(phone(app: "支付宝", tint: 0x1677FF, nav: "收银台",
           cards: [[("商品", "视频会员季卡"), ("应付金额", "¥45.00"), ("支付结果", "交易失败：余额不足，请更换付款方式")]],
           statusText: "支付失败", statusColor: 0xD5281F), "x08_pay_failed.png")

save(chatScreenshot(), "x03_chat_records.png")
save(listNote(), "x05_shopping_list.png")
save(plainTest(), "x04_test_plain.png")

// —— 外币 ——
save(receipt(name: "Whole Foods Market", addr: "Store #102 · Portland OR", dateLine: "09/02/2026 18:40  Reg 03",
             items: [("Organic Bananas", 3.99), ("Whole Milk 1Gal", 4.49), ("Sourdough Bread", 5.99)],
             payLabel: "VISA ****8821  PAID $14.47", footer: "THANK YOU"), "f01_usd_visa.png")

print("\n完成：24 张样张已写入 \(outDir)/")
