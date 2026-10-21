//
//  UnifiedIconCatalog.swift
//  Holo
//
//  用户自建实体（习惯/财务项目/记账分类）统一单色图标精选目录
//  12 分组 · 120 唯一图标（SF Symbol 113 + 自绘资产 7）
//  定稿与拍板记录见 docs/_common/notes/2026-10-21-用户自建实体图标体系统一-盘点与映射表.md
//  SF Symbol 名存在性由 HoloTests（HabitIconPresetsTests.swift）断言兜底
//

import Foundation

nonisolated enum UnifiedIconCatalog {

    // MARK: - 模型

    struct Item: Identifiable {
        /// SF Symbol 名或 Asset Catalog 资产名
        let name: String
        /// 中文标签
        let label: String
        /// 是否为 Asset Catalog 自绘资产
        let isAsset: Bool

        var id: String { name }

        init(name: String, label: String, isAsset: Bool = false) {
            self.name = name
            self.label = label
            self.isAsset = isAsset
        }
    }

    struct Section: Identifiable {
        let id: String
        let title: String
        /// 分组标题小图标（SF Symbol，仅展示不占精选名额）
        let icon: String
        let items: [Item]
    }

    // MARK: - 目录

    static let sections: [Section] = [
        Section(id: "sport", title: String(localized: "运动健身"), icon: "figure.run", items: [
            Item(name: "figure.walk", label: String(localized: "散步")),
            Item(name: "figure.run", label: String(localized: "跑步")),
            Item(name: "dumbbell.fill", label: String(localized: "健身")),
            Item(name: "figure.yoga", label: String(localized: "瑜伽")),
            Item(name: "figure.pool.swim", label: String(localized: "游泳")),
            Item(name: "bicycle", label: String(localized: "骑行")),
            Item(name: "figure.jumprope", label: String(localized: "跳绳")),
            Item(name: "figure.step.training", label: String(localized: "步数")),
            Item(name: "figure.flexibility", label: String(localized: "拉伸")),
            Item(name: "sportscourt.fill", label: String(localized: "球类")),
            Item(name: "trophy.fill", label: String(localized: "夺冠")),
            Item(name: "figure.mind.and.body", label: String(localized: "身心")),
            Item(name: "heart.fill", label: String(localized: "心率")),
        ]),
        Section(id: "health", title: String(localized: "健康身体"), icon: "stethoscope", items: [
            Item(name: "drop.fill", label: String(localized: "喝水")),
            Item(name: "bed.double.fill", label: String(localized: "睡眠")),
            Item(name: "moon.fill", label: String(localized: "早睡")),
            Item(name: "sun.max.fill", label: String(localized: "早起")),
            Item(name: "brain.head.profile", label: String(localized: "冥想")),
            Item(name: "pill.fill", label: String(localized: "服药")),
            Item(name: "cross.case.fill", label: String(localized: "医疗")),
            Item(name: "scalemass.fill", label: String(localized: "体重")),
            Item(name: "eye.fill", label: String(localized: "护眼")),
            Item(name: "bandage.fill", label: String(localized: "护理")),
            Item(name: "hand.raised.fill", label: String(localized: "护肤")),
            Item(name: "figure.stand", label: String(localized: "站立")),
        ]),
        Section(id: "learning", title: String(localized: "学习成长"), icon: "book.fill", items: [
            Item(name: "book.fill", label: String(localized: "阅读")),
            Item(name: "book.closed.fill", label: String(localized: "书本")),
            Item(name: "character.book.closed.fill", label: String(localized: "外语")),
            Item(name: "pencil", label: String(localized: "写作")),
            Item(name: "doc.text.fill", label: String(localized: "文档")),
            Item(name: "graduationcap.fill", label: String(localized: "课程")),
            Item(name: "lightbulb.fill", label: String(localized: "灵感")),
            Item(name: "puzzlepiece.fill", label: String(localized: "技能")),
            Item(name: "chevron.left.forwardslash.chevron.right", label: String(localized: "编程")),
            Item(name: "highlighter", label: String(localized: "划重点")),
            Item(name: "checkmark.rectangle.fill", label: String(localized: "打卡")),
        ]),
        Section(id: "food", title: String(localized: "饮食"), icon: "fork.knife", items: [
            Item(name: "fork.knife", label: String(localized: "正餐")),
            Item(name: "finance_breakfast", label: String(localized: "早餐"), isAsset: true),
            Item(name: "finance_fruit", label: String(localized: "水果"), isAsset: true),
            Item(name: "finance_hotpot", label: String(localized: "火锅"), isAsset: true),
            Item(name: "finance_dessert", label: String(localized: "甜点"), isAsset: true),
            Item(name: "finance_coffee", label: String(localized: "咖啡"), isAsset: true),
            Item(name: "finance_tea", label: String(localized: "茶"), isAsset: true),
            Item(name: "cup.and.saucer.fill", label: String(localized: "咖啡杯")),
            Item(name: "wineglass.fill", label: String(localized: "酒")),
            Item(name: "takeoutbag.and.cup.and.straw.fill", label: String(localized: "外带")),
            Item(name: "birthday.cake.fill", label: String(localized: "蛋糕")),
        ]),
        Section(id: "transport", title: String(localized: "出行交通"), icon: "car.fill", items: [
            Item(name: "car.fill", label: String(localized: "汽车")),
            Item(name: "car.side.fill", label: String(localized: "出行")),
            Item(name: "bus.fill", label: String(localized: "公交")),
            Item(name: "train.side.front.car", label: String(localized: "地铁火车")),
            Item(name: "tram.fill", label: String(localized: "有轨电车")),
            Item(name: "airplane", label: String(localized: "飞机")),
            Item(name: "airplane.departure", label: String(localized: "航班")),
            Item(name: "sailboat.fill", label: String(localized: "船艇")),
            Item(name: "scooter", label: String(localized: "小型电动车")),
            Item(name: "fuelpump.fill", label: String(localized: "加油")),
            Item(name: "parkingsign.circle.fill", label: String(localized: "停车")),
        ]),
        Section(id: "home", title: String(localized: "家居生活"), icon: "house.fill", items: [
            Item(name: "house.fill", label: String(localized: "住所")),
            Item(name: "key.fill", label: String(localized: "房租")),
            Item(name: "building.2.fill", label: String(localized: "物业")),
            Item(name: "bolt.fill", label: String(localized: "电费")),
            Item(name: "flame.fill", label: String(localized: "燃气")),
            Item(name: "wifi", label: String(localized: "网络")),
            Item(name: "wrench.fill", label: String(localized: "维修")),
            Item(name: "trash.fill", label: String(localized: "清洁")),
            Item(name: "shower.fill", label: String(localized: "洗浴")),
            Item(name: "paintbrush.fill", label: String(localized: "翻新")),
            Item(name: "phone.fill", label: String(localized: "通讯")),
            Item(name: "basket.fill", label: String(localized: "采购")),
        ]),
        Section(id: "finance", title: String(localized: "金钱事务"), icon: "yensign.circle.fill", items: [
            Item(name: "yensign.circle.fill", label: String(localized: "人民币")),
            Item(name: "banknote.fill", label: String(localized: "现金")),
            Item(name: "dollarsign.circle.fill", label: String(localized: "储蓄")),
            Item(name: "chart.line.uptrend.xyaxis", label: String(localized: "投资")),
            Item(name: "chart.pie.fill", label: String(localized: "配置")),
            Item(name: "creditcard.fill", label: String(localized: "信用卡")),
            Item(name: "percent", label: String(localized: "利息")),
            Item(name: "briefcase.fill", label: String(localized: "工资")),
            Item(name: "building.columns.fill", label: String(localized: "银行")),
            Item(name: "receipt", label: String(localized: "发票")),
            Item(name: "shippingbox.fill", label: String(localized: "快递")),
        ]),
        Section(id: "entertainment", title: String(localized: "娱乐创造"), icon: "party.popper", items: [
            Item(name: "music.note.list", label: String(localized: "音乐")),
            Item(name: "film.fill", label: String(localized: "电影")),
            Item(name: "gamecontroller.fill", label: String(localized: "游戏")),
            Item(name: "guitars.fill", label: String(localized: "乐器")),
            Item(name: "mic.fill", label: String(localized: "唱歌")),
            Item(name: "camera.fill", label: String(localized: "摄影")),
            Item(name: "paintpalette", label: String(localized: "绘画")),
            Item(name: "dice.fill", label: String(localized: "桌游")),
            Item(name: "party.popper", label: String(localized: "庆祝")),
            Item(name: "ticket.fill", label: String(localized: "展演")),
            Item(name: "photo.artframe", label: String(localized: "展览")),
        ]),
        Section(id: "social", title: String(localized: "人际情感"), icon: "person.2.fill", items: [
            Item(name: "person.2.fill", label: String(localized: "社交")),
            Item(name: "figure.and.child.holdinghands", label: String(localized: "亲子")),
            Item(name: "person.crop.circle.badge.checkmark", label: String(localized: "人脉")),
            Item(name: "face.smiling.fill", label: String(localized: "心情")),
            Item(name: "hands.clap.fill", label: String(localized: "鼓掌")),
            Item(name: "gift.fill", label: String(localized: "礼物")),
            Item(name: "heart.text.square.fill", label: String(localized: "感恩")),
            Item(name: "bubble.left.and.bubble.right.fill", label: String(localized: "聊天")),
            Item(name: "star.fill", label: String(localized: "喜爱")),
        ]),
        Section(id: "nature", title: String(localized: "自然植物"), icon: "leaf.fill", items: [
            Item(name: "leaf.fill", label: String(localized: "绿植")),
            Item(name: "tree.fill", label: String(localized: "树木")),
            Item(name: "sparkles", label: String(localized: "闪光")),
            Item(name: "pawprint.fill", label: String(localized: "宠物")),
            Item(name: "sun.horizon.fill", label: String(localized: "日出")),
            Item(name: "cloud.fill", label: String(localized: "天气")),
        ]),
        Section(id: "restraint", title: String(localized: "自律戒除"), icon: "xmark.shield.fill", items: [
            Item(name: "habit_nosmoking", label: String(localized: "戒烟"), isAsset: true),
            Item(name: "xmark.shield.fill", label: String(localized: "戒除")),
            Item(name: "iphone.slash", label: String(localized: "少玩手机")),
            Item(name: "moon.zzz.fill", label: String(localized: "少熬夜")),
            Item(name: "bell.slash.fill", label: String(localized: "少刷视频")),
            Item(name: "minus.circle.fill", label: String(localized: "减少")),
            Item(name: "timer", label: String(localized: "控制")),
        ]),
        Section(id: "general", title: String(localized: "通用"), icon: "checkmark.circle", items: [
            Item(name: "checkmark.circle", label: String(localized: "打卡")),
            Item(name: "target", label: String(localized: "目标")),
            Item(name: "tag.fill", label: String(localized: "标签")),
            Item(name: "flag.fill", label: String(localized: "里程碑")),
            Item(name: "bookmark.fill", label: String(localized: "收藏")),
            Item(name: "clock.fill", label: String(localized: "时间")),
        ]),
    ]

    // MARK: - 派生

    /// 扁平化全部图标名（保持分组顺序）
    static let allNames: [String] = sections.flatMap { $0.items.map(\.name) }

    static func contains(_ name: String) -> Bool {
        allNames.contains(name)
    }

    /// 图标名是否为 Asset Catalog 自绘资产（供渲染层走 template 染色分支）。
    /// 按前缀识别而非精选集成员判断：存量数据里的历史资产（如分类的 finance_movie）
    /// 不在精选 120 内，仍需按资产正常渲染，展示不受精选集收敛影响。
    /// 真源在 EntityIconAsset（HabitType.swift，Widget 扩展同样可见）。
    static func isAssetIcon(_ name: String) -> Bool {
        EntityIconAsset.isAsset(name)
    }
}
