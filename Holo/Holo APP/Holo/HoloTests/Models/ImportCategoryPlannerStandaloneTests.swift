import Foundation

@main
struct ImportCategoryPlannerStandaloneTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }

    static func main() {
        let existing = [
            ImportCategoryDescriptor(typeRaw: "expense", primaryName: "餐饮", subName: nil),
            ImportCategoryDescriptor(typeRaw: "expense", primaryName: "餐饮", subName: "咖啡"),
        ]

        let incoming = [
            ImportCategoryDescriptor(typeRaw: "expense", primaryName: "餐饮", subName: "咖啡"),
            ImportCategoryDescriptor(typeRaw: "expense", primaryName: "购物", subName: "咖啡"),
            ImportCategoryDescriptor(typeRaw: "income", primaryName: "购物", subName: "咖啡"),
            ImportCategoryDescriptor(typeRaw: "expense", primaryName: "生活服务", subName: "生活服务"),
        ]

        let plan = ImportCategoryPlanner.makePlan(
            incoming: incoming,
            existing: existing
        )

        expect(
            plan.reusedLeafCategoryKeys == Set(["expense|餐饮|咖啡"]),
            "只应该复用完全相同 type + 一级 + 二级 的既有分类"
        )

        expect(
            plan.primaryCategoriesToCreate == [
                ImportCategoryDescriptor(typeRaw: "expense", primaryName: "购物", subName: nil),
                ImportCategoryDescriptor(typeRaw: "income", primaryName: "购物", subName: nil),
                ImportCategoryDescriptor(typeRaw: "expense", primaryName: "生活服务", subName: nil),
            ],
            "不同 type 或不同一级分类下的同名科目必须分别创建一级分类"
        )

        expect(
            plan.subCategoriesToCreate == [
                ImportCategoryDescriptor(typeRaw: "expense", primaryName: "购物", subName: "咖啡"),
                ImportCategoryDescriptor(typeRaw: "income", primaryName: "购物", subName: "咖啡"),
            ],
            "同名二级科目在不同一级分类或交易类型下必须分别创建"
        )

        print("ImportCategoryPlanner standalone tests passed")
    }
}
