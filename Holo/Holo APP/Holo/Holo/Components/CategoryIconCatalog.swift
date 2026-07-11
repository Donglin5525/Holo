//
//  CategoryIconCatalog.swift
//  Holo
//
//  记账模块图标目录
//  13 个展示分组，共 255+ 个图标
//  仅用于 IconPickerGrid 的 UI 展示分组，不代表业务分类
//

import Foundation

// MARK: - Section Model

/// 图标选择器的展示分组
struct IconPickerSection: Identifiable {
    let id: String
    let title: String
    let icons: [String]
}

// MARK: - Icon Catalog

/// 图标目录 — 单一数据源
enum CategoryIconCatalog {

    // MARK: - 13 个展示分组

    static let sections: [IconPickerSection] = [
        IconPickerSection(id: "food", title: "餐饮", icons: [
            // 现有 12 个
            "fork.knife", "sunrise.fill", "sun.max.fill", "moon.stars.fill",
            "moonphase.waning.crescent", "popcorn.fill", "cup.and.saucer.fill",
            "bag.fill", "wineglass.fill", "carrot.fill", "wineglass", "cart.fill",
            // 新增 5 个
            "takeoutbag.and.cup.and.straw.fill", "mug.fill", "birthday.cake.fill",
            "stove.fill", "flame.circle.fill",
        ]),

        IconPickerSection(id: "transport", title: "交通", icons: [
            // 现有 12 个
            "car.fill", "train.side.front.car", "car.side.fill", "fuelpump.fill",
            "parkingsign.circle.fill", "building.columns.fill", "bicycle",
            "airplane", "figure.walk", "bus.fill", "train.side.rear.car", "airplane.departure",
            // 新增 6 个
            "tram.fill", "sailboat.fill", "bolt.car.fill", "scooter",
            "figure.roll.runningpace", "ferry", "car.rear.waves.up.fill",
            "wrench.and.screwdriver.fill",
        ]),

        IconPickerSection(id: "entertainment", title: "娱乐", icons: [
            // 现有 6 个
            "music.note.list", "film.fill", "mic.fill", "gamecontroller.fill",
            "play.tv.fill", "figure.run",
            // 新增 10 个（含 party.popper 共 9 个新图标）
            "theatermasks.fill", "photo.artframe", "camera.fill", "dice.fill",
            "puzzlepiece.fill", "guitars.fill", "party.popper", "ticket.fill",
            "gamecontroller.circle.fill",
        ]),

        IconPickerSection(id: "shopping", title: "购物", icons: [
            // 现有 8 个
            "hanger", "desktopcomputer", "basket.fill", "sparkles",
            "sofa.fill", "book.fill", "sportscourt.fill", "gift.fill",
            // 新增 8 个
            "backpack.fill", "diamond.fill", "crown.fill", "shoe.fill",
            "figure.dress.line.vertical.figure", "creditcard.fill",
            "storefront.fill", "bag.circle.fill",
        ]),

        IconPickerSection(id: "personalCare", title: "个人护理", icons: [
            // 现有 2 个（跨组调整：dumbbell.fill 从医疗移入，scissors 从其他移入）
            "dumbbell.fill", "scissors",
            // 新增 11 个
            "person.fill", "face.smiling.fill", "hand.raised.fill", "eyeglasses",
            "figure.yoga", "tshirt.fill", "hand.wave.fill", "wand.and.stars",
            "water.waves", "bubbles.and.sparkles.fill", "drop.circle.fill",
        ]),

        IconPickerSection(id: "home", title: "家居", icons: [
            // 现有 11 个
            "house.fill", "key.fill", "building.2.fill", "drop.fill",
            "bolt.fill", "flame.fill", "wifi", "wrench.fill",
            "banknote.fill", "tv.fill", "paintbrush.fill",
            // 新增 7 个
            "bed.double.fill", "lamp.table.fill", "shower.fill",
            "lock.shield.fill", "fanblades.fill", "trash.fill",
            "sparkles.square.filled.on.square",
        ]),

        IconPickerSection(id: "health", title: "医疗健康", icons: [
            // 现有 6 个（dumbbell.fill 已移至个人护理）
            "heart.text.square.fill", "stethoscope", "pill.fill",
            "leaf.fill", "heart.circle.fill", "cross.case.fill",
            // 新增 7 个
            "syringe.fill", "eye.fill", "mouth.fill", "bandage.fill",
            "allergens", "figure.mind.and.body", "heart.text.clipboard.fill",
        ]),

        IconPickerSection(id: "learning", title: "学习成长", icons: [
            // 现有 3 个
            "book.closed.fill", "text.book.closed.fill", "checkmark.rectangle.fill",
            // 新增 8 个
            "character.book.closed.fill", "laptopcomputer.and.iphone",
            "studentdesk", "doc.text.fill", "bubble.left.and.bubble.right.fill",
            "magazine.fill", "highlighter", "rosette", "cloud.fill", "laptopcomputer",
        ]),

        IconPickerSection(id: "family", title: "家庭人情", icons: [
            // 现有 6 个（原人情类 3 个 + 社交类 3 个合并）
            "yensign.circle.fill", "figure.walk.arrival", "ellipsis.circle.fill",
            "person.2.fill", "heart.fill", "trophy.fill",
            // 新增 8 个
            "figure.and.child.holdinghands", "graduationcap.fill",
            "figure.stand.dress", "balloon.fill", "figure.socialdance",
            "giftcard.fill", "gift.circle.fill", "bubble.left.fill",
            "person.2.badge.gearshape.fill",
        ]),

        IconPickerSection(id: "lifeServices", title: "生活服务", icons: [
            // 现有 3 个（从原其他支出拆出）
            "pawprint.fill", "washer.fill", "phone.fill",
            // 新增 5 个
            "tree.fill", "qrcode", "hourglass", "bookmark.fill",
            "globe.asia.australia.fill", "shippingbox.and.arrow.backward.fill",
        ]),

        IconPickerSection(id: "income", title: "收入资产", icons: [
            // 现有 13 个（原投资理财类 + 其他收入合并）
            "percent", "star.fill", "chart.line.uptrend.xyaxis",
            "chart.pie.fill", "briefcase.fill",
            "arrow.uturn.backward.circle.fill", "arrow.counterclockwise.circle.fill",
            "arrow.left.circle.fill", "arrow.down.circle.fill",
            "arrow.uturn.forward.circle.fill", "shippingbox.fill",
            "arrow.3.trianglepath", "plus.circle.fill",
            // 新增 3 个
            "bitcoinsign.circle.fill", "arrow.up.circle.fill",
            "building.columns.circle.fill", "person.crop.circle.badge.checkmark",
        ]),

        IconPickerSection(id: "other", title: "其他", icons: [
            // 现有 6 个（从原其他支出拆出）
            "smoke.fill", "shield.checkered", "arrow.right.circle.fill",
            "questionmark.folder.fill", "pencil.line", "arrow.trianglehead.clockwise",
            // 新增 5 个
            "exclamationmark.triangle.fill", "xmark.circle.fill",
            "arrow.right.arrow.left.circle.fill", "hands.clap.fill",
            "rectangle.portrait.and.arrow.right.fill", "dollarsign.arrow.circlepath",
            "holo.category.generic", "holo.category.misc",
        ]),

        // 财务重绘图标（来自 finance v3 SVG 资源包）
        IconPickerSection(id: "financeV3", title: "财务重绘", icons: [
            "finance_breakfast", "finance_lunch", "finance_dinner", "finance_latenight",
            "finance_snack", "finance_coffee", "finance_takeout", "finance_drink",
            "finance_fruit", "finance_alcohol", "finance_supermarket", "finance_subway",
            "finance_taxi", "finance_bus", "finance_bicycle", "finance_fuel",
            "finance_ev_charge", "finance_parking", "finance_carwash", "finance_carmaint",
            "finance_train", "finance_flight", "finance_travel", "finance_toll",
            "finance_fine", "finance_clothes", "finance_digital", "finance_daily",
            "finance_cosmetics", "finance_furniture", "finance_books", "finance_sports",
            "finance_gift", "finance_movie", "finance_game", "finance_video",
            "finance_music", "finance_ktv", "finance_tourism", "finance_hotel",
            "finance_ticket", "finance_gym", "finance_rent", "finance_mortgage",
            "finance_water", "finance_electricity", "finance_gas", "finance_property",
            "finance_internet", "finance_appliance", "finance_renovation", "finance_cleaning",
            "finance_moving", "finance_doctor", "finance_medicine", "finance_checkup",
            "finance_supplement", "finance_dental", "finance_medical_supply", "finance_course",
            "finance_textbook", "finance_exam", "finance_stationery", "finance_subscription",
            "finance_treat", "finance_present", "finance_support", "finance_social",
            "finance_express", "finance_repayment", "finance_insurance", "finance_investment",
            "finance_transfer", "finance_other_expense", "finance_salary", "finance_bonus",
            "finance_parttime", "finance_invest_return", "finance_wealth_return", "finance_refund",
            "finance_reimbursement", "finance_red_packet", "finance_transfer_in", "finance_other_income",
        ]),

        // 财务 v4 新增的一级分类与细分科目图标
        IconPickerSection(id: "financeV4", title: "财务重绘 v4", icons: [
            "cat_food", "cat_transport", "cat_shopping", "cat_entertain", "cat_housing",
            "cat_medical", "cat_learning", "cat_relation", "cat_other_exp",
            "cat_inc_invest", "cat_inc_salary", "cat_inc_relation", "cat_inc_other",
            "finance_hotpot", "finance_bbq", "finance_dessert", "finance_beer", "finance_tea",
            "finance_ship", "finance_ferry", "finance_scooter", "finance_car_rent",
            "finance_shoes", "finance_jewelry", "finance_toy", "finance_pet_supply",
            "finance_plant", "finance_food_buy", "finance_sports_event", "finance_concert",
            "finance_exhibition", "finance_spa", "finance_escape", "finance_outdoor",
            "finance_phone_bill", "finance_security", "finance_laundry", "finance_furniture_rent",
            "finance_hospital", "finance_glasses", "finance_psychology", "finance_fitness_med",
            "finance_vaccine", "finance_ai_tool", "finance_software", "finance_cloud",
            "finance_language", "finance_music_learn", "finance_art", "finance_sport_learn",
            "finance_certificate", "finance_red_env", "finance_visit", "finance_child",
            "finance_donation", "finance_haircut", "finance_laundry2", "finance_phone",
            "finance_tobacco", "finance_repair", "finance_fee", "finance_tax",
            "finance_penalty", "finance_delivery", "finance_charity", "finance_pet", "finance_other_exp",
            "finance_wedding", "income_interest", "income_stock", "income_fund",
            "income_rent_in", "income_other_invest", "income_crypto", "income_dividend",
            "income_salary", "income_bonus", "income_parttime", "income_project",
            "income_consulting", "income_reimburse", "income_refund", "income_royalty",
            "income_commission", "income_red_packet", "income_gift_in", "income_lottery",
            "income_transfer_in", "income_crowd", "income_sponsor", "income_borrow",
            "income_repay_in", "income_return_goods", "income_provident", "income_secondhand",
            "income_manuscript", "income_subsidy", "income_tax_refund", "income_insurance_pay",
            "income_rent_deposit", "income_award", "income_other",
        ]),
    ]

    // MARK: - Derived Properties

    /// 所有图标的扁平列表，从 sections 派生，保持分组顺序
    static let allIcons: [String] = {
        sections.flatMap(\.icons)
    }()

    /// SwiftUI 自绘图标，不是 SF Symbol
    static let customIconNames: Set<String> = [
        "holo.category.breakfast",
        "holo.category.lunch",
        "holo.category.dinner",
        "holo.category.fruit",
        "holo.category.generic",
        "holo.category.misc",
    ]

    /// 仅 SF Symbol 图标，用于系统符号可解析性测试
    static let sfSymbolIcons: [String] = {
        allIcons.filter { !customIconNames.contains($0) }
    }()

    static func isCustomIcon(_ icon: String) -> Bool {
        customIconNames.contains(icon)
    }

    /// 判断指定图标是否在目录中
    static func contains(_ icon: String) -> Bool {
        allIcons.contains(icon)
    }

    // MARK: - Legacy (Test Only)

    /// 原 88 个预设图标集合，仅用于测试兼容性校验
    static let legacyPresetIcons: Set<String> = [
        // 餐饮类
        "fork.knife", "sunrise.fill", "sun.max.fill", "moon.stars.fill",
        "moonphase.waning.crescent", "popcorn.fill", "cup.and.saucer.fill",
        "bag.fill", "wineglass.fill", "carrot.fill", "wineglass", "cart.fill",
        // 交通类
        "car.fill", "train.side.front.car", "car.side.fill", "fuelpump.fill",
        "parkingsign.circle.fill", "building.columns.fill", "bicycle",
        "airplane", "figure.walk", "bus.fill", "train.side.rear.car", "airplane.departure",
        // 购物类
        "hanger", "desktopcomputer", "basket.fill", "sparkles",
        "sofa.fill", "book.fill", "sportscourt.fill", "gift.fill",
        // 娱乐类
        "music.note.list", "film.fill", "mic.fill", "gamecontroller.fill",
        "play.tv.fill", "figure.run",
        // 居住类
        "house.fill", "key.fill", "building.2.fill", "drop.fill",
        "bolt.fill", "flame.fill", "wifi", "wrench.fill",
        "banknote.fill", "tv.fill", "paintbrush.fill",
        // 医疗类（含 dumbbell.fill）
        "heart.text.square.fill", "stethoscope", "pill.fill",
        "leaf.fill", "heart.circle.fill", "cross.case.fill", "dumbbell.fill",
        // 学习类
        "book.closed.fill", "text.book.closed.fill", "checkmark.rectangle.fill",
        // 人情类
        "yensign.circle.fill", "figure.walk.arrival", "ellipsis.circle.fill",
        // 社交类
        "person.2.fill", "heart.fill", "trophy.fill",
        // 投资理财类（收入）
        "percent", "star.fill", "chart.line.uptrend.xyaxis",
        "chart.pie.fill", "briefcase.fill",
        "arrow.uturn.backward.circle.fill", "arrow.counterclockwise.circle.fill",
        // 其他收入
        "arrow.left.circle.fill", "arrow.down.circle.fill",
        "arrow.uturn.forward.circle.fill", "shippingbox.fill",
        "arrow.3.trianglepath", "plus.circle.fill",
        // 其他支出（含 scissors, pawprint.fill, washer.fill, phone.fill）
        "pawprint.fill", "scissors", "washer.fill",
        "phone.fill", "smoke.fill", "shield.checkered",
        "arrow.right.circle.fill", "questionmark.folder.fill",
        "pencil.line", "arrow.trianglehead.clockwise",
    ]
}
