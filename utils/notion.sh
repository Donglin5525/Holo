#!/bin/bash
# Notion API 工具脚本
# 用法: ./notion.sh <command> [args]
#
# 读取命令:
#   search <query>          - 搜索页面
#   get <page_id>           - 获取页面内容
#   list                    - 列出所有可访问的页面
#   raw <page_id>           - 获取原始 JSON 数据
#
# 写入命令:
#   create <parent_id> <title>              - 在父页面下创建子页面
#   append <page_id> <content>              - 追加文本内容到页面
#   append-file <page_id> <file_path>       - 从文件追加内容到页面
#   append-heading <page_id> <level> <text> - 追加标题（level: 1-3）
#   append-list <page_id> <item1|item2|...> - 追加无序列表
#   append-todo <page_id> <text> [checked]  - 追加待办项（checked: true/false）
#   append-code <page_id> <language> <code> - 追加代码块
#   append-divider <page_id>                - 追加分割线

# API 配置
NOTION_API_KEY="${NOTION_API_KEY:-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}"
NOTION_VERSION="2022-06-28"
API_BASE="https://api.notion.com/v1"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 通用 API 请求函数
api_request() {
    local method="$1"
    local endpoint="$2"
    local data="$3"

    curl -s -X "$method" "${API_BASE}${endpoint}" \
        -H "Authorization: Bearer ${NOTION_API_KEY}" \
        -H "Content-Type: application/json" \
        -H "Notion-Version: ${NOTION_VERSION}" \
        ${data:+-d "$data"}
}

# 搜索页面
search_pages() {
    local query="$1"
    local json

    if [[ -n "$query" ]]; then
        json=$(api_request "POST" "/search" "{\"query\": \"$query\", \"page_size\": 20}")
    else
        json=$(api_request "POST" "/search" "{\"page_size\": 20}")
    fi

    echo "$json" | jq -r '
        .results[] |
        if .object == "page" then
            "📄 \(.properties.title.title[0].plain_text // "无标题") (ID: \(.id))"
        elif .object == "database" then
            "📊 \(.title[0].plain_text // "无标题") (ID: \(.id))"
        else
            empty
        end
    ' 2>/dev/null
}

# 列出所有页面
list_all() {
    local json
    json=$(api_request "POST" "/search" '{"page_size": 50, "filter": {"property": "object", "value": "page"}}')

    echo -e "${BLUE}📚 可访问的页面列表:${NC}\n"
    echo "$json" | jq -r '
        .results[] |
        "  \(.properties.title.title[0].plain_text // "无标题")\n    ID: \(.id)\n    最后编辑: \(.last_edited_time)\n"
    ' 2>/dev/null
}

# 解析并格式化页面内容
parse_content() {
    local json="$1"

    echo "$json" | jq -r '
        .results[] |
        if .type == "paragraph" and .paragraph.rich_text then
            .paragraph.rich_text[].plain_text // ""
        elif .type == "heading_1" and .heading_1.rich_text then
            "\n# " + (.heading_1.rich_text[].plain_text // "")
        elif .type == "heading_2" and .heading_2.rich_text then
            "\n## " + (.heading_2.rich_text[].plain_text // "")
        elif .type == "heading_3" and .heading_3.rich_text then
            "\n### " + (.heading_3.rich_text[].plain_text // "")
        elif .type == "bulleted_list_item" and .bulleted_list_item.rich_text then
            "- " + (.bulleted_list_item.rich_text[].plain_text // "")
        elif .type == "numbered_list_item" and .numbered_list_item.rich_text then
            "1. " + (.numbered_list_item.rich_text[].plain_text // "")
        elif .type == "to_do" and .to_do.rich_text then
            "[" + (if .to_do.checked then "x" else " " end) + "] " + (.to_do.rich_text[].plain_text // "")
        elif .type == "toggle" and .toggle.rich_text then
            "▶ " + (.toggle.rich_text[].plain_text // "")
        elif .type == "callout" and .callout.rich_text then
            "💡 " + (.callout.rich_text[].plain_text // "")
        elif .type == "quote" and .quote.rich_text then
            "> " + (.quote.rich_text[].plain_text // "")
        elif .type == "code" and .code.rich_text then
            "\n```" + (.code.language // "") + "\n" + (.code.rich_text[].plain_text // "") + "\n```\n"
        elif .type == "divider" then
            "\n---\n"
        elif .type == "child_page" then
            "\n📎 子页面: " + .child_page.title + " (ID: " + .id + ")"
        elif .type == "child_database" then
            "\n📊 子数据库: " + .child_database.title + " (ID: " + .id + ")"
        else
            empty
        end
    ' 2>/dev/null
}

# 获取页面内容
get_page() {
    local page_id="$1"

    if [[ -z "$page_id" ]]; then
        echo -e "${RED}错误: 请提供页面 ID${NC}"
        return 1
    fi

    # 移除 ID 中的连字符（Notion API 接受两种格式）
    page_id=$(echo "$page_id" | tr -d '-')

    # 获取页面信息
    local page_info
    page_info=$(api_request "GET" "/pages/${page_id}")

    local title
    title=$(echo "$page_info" | jq -r '.properties.title.title[0].plain_text // "无标题"' 2>/dev/null)

    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}📄 $title${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

    # 获取页面内容
    local content
    content=$(api_request "GET" "/blocks/${page_id}/children?page_size=100")

    parse_content "$content"

    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 获取原始 JSON
get_raw() {
    local page_id="$1"

    if [[ -z "$page_id" ]]; then
        echo -e "${RED}错误: 请提供页面 ID${NC}"
        return 1
    fi

    page_id=$(echo "$page_id" | tr -d '-')

    api_request "GET" "/blocks/${page_id}/children?page_size=100" | jq '.'
}

# ============================================
# 写入功能
# ============================================

# 创建新页面
create_page() {
    local parent_id="$1"
    local title="$2"

    if [[ -z "$parent_id" ]] || [[ -z "$title" ]]; then
        echo -e "${RED}错误: 请提供父页面 ID 和标题${NC}"
        echo "用法: $0 create <parent_id> <title>"
        return 1
    fi

    parent_id=$(echo "$parent_id" | tr -d '-')

    local json
    json=$(api_request "POST" "/pages" "{
        \"parent\": { \"page_id\": \"$parent_id\" },
        \"properties\": {
            \"title\": [{ \"text\": { \"content\": \"$title\" } }]
        }
    }")

    local new_id
    new_id=$(echo "$json" | jq -r '.id // empty')

    if [[ -n "$new_id" ]]; then
        echo -e "${GREEN}✅ 页面创建成功!${NC}"
        echo -e "   标题: ${YELLOW}$title${NC}"
        echo -e "   ID: $new_id"
        echo "$new_id"
    else
        echo -e "${RED}❌ 创建失败${NC}"
        echo "$json" | jq '.'
    fi
}

# 追加块到页面
append_blocks() {
    local page_id="$1"
    local blocks_json="$2"

    if [[ -z "$page_id" ]] || [[ -z "$blocks_json" ]]; then
        echo -e "${RED}错误: 请提供页面 ID 和内容${NC}"
        return 1
    fi

    page_id=$(echo "$page_id" | tr -d '-')

    local json
    json=$(api_request "PATCH" "/blocks/${page_id}/children" "{
        \"children\": $blocks_json
    }")

    if echo "$json" | jq -e '.results' > /dev/null 2>&1; then
        echo -e "${GREEN}✅ 内容已追加${NC}"
    else
        echo -e "${RED}❌ 追加失败${NC}"
        echo "$json" | jq '.'
    fi
}

# 追加文本段落
append_text() {
    local page_id="$1"
    local content="$2"

    # 转义特殊字符
    local escaped_content
    escaped_content=$(echo "$content" | jq -Rs '.' | sed 's/^"//;s/"$//')

    append_blocks "$page_id" "[{
        \"type\": \"paragraph\",
        \"paragraph\": {
            \"rich_text\": [{ \"type\": \"text\", \"text\": { \"content\": \"$escaped_content\" } }]
        }
    }]"
}

# 从文件追加内容
append_file() {
    local page_id="$1"
    local file_path="$2"

    if [[ ! -f "$file_path" ]]; then
        echo -e "${RED}错误: 文件不存在 - $file_path${NC}"
        return 1
    fi

    local content
    content=$(cat "$file_path")

    # 按行分割并转换为块
    local blocks="["
    local first=true
    local in_code_block=false
    local code_content=""
    local code_lang=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # 检测代码块
        if [[ "$line" =~ ^\`\`\` ]]; then
            if [[ "$in_code_block" == false ]]; then
                in_code_block=true
                code_lang=$(echo "$line" | sed 's/^\`\`\`//')
                code_content=""
            else
                # 结束代码块
                in_code_block=false
                local escaped_code
                escaped_code=$(echo "$code_content" | jq -Rs '.' | sed 's/^"//;s/"$//')
                if [[ "$first" == false ]]; then blocks+=","; fi
                blocks+="{
                    \"type\": \"code\",
                    \"code\": {
                        \"language\": \"${code_lang:-plain text}\",
                        \"rich_text\": [{ \"type\": \"text\", \"text\": { \"content\": \"$escaped_code\" } }]
                    }
                }"
                first=false
            fi
            continue
        fi

        if [[ "$in_code_block" == true ]]; then
            code_content+="$line\n"
            continue
        fi

        # 检测标题
        local block_json=""
        if [[ "$line" =~ ^###\ (.+) ]]; then
            local text="${BASH_REMATCH[1]}"
            text=$(echo "$text" | jq -Rs '.' | sed 's/^"//;s/"$//')
            block_json="{\"type\": \"heading_3\", \"heading_3\": {\"rich_text\": [{\"type\": \"text\", \"text\": {\"content\": \"$text\"}}]}}"
        elif [[ "$line" =~ ^##\ (.+) ]]; then
            local text="${BASH_REMATCH[1]}"
            text=$(echo "$text" | jq -Rs '.' | sed 's/^"//;s/"$//')
            block_json="{\"type\": \"heading_2\", \"heading_2\": {\"rich_text\": [{\"type\": \"text\", \"text\": {\"content\": \"$text\"}}]}}"
        elif [[ "$line" =~ ^#\ (.+) ]]; then
            local text="${BASH_REMATCH[1]}"
            text=$(echo "$text" | jq -Rs '.' | sed 's/^"//;s/"$//')
            block_json="{\"type\": \"heading_1\", \"heading_1\": {\"rich_text\": [{\"type\": \"text\", \"text\": {\"content\": \"$text\"}}]}}"
        elif [[ "$line" =~ ^-\ (.+) ]]; then
            local text="${BASH_REMATCH[1]}"
            text=$(echo "$text" | jq -Rs '.' | sed 's/^"//;s/"$//')
            block_json="{\"type\": \"bulleted_list_item\", \"bulleted_list_item\": {\"rich_text\": [{\"type\": \"text\", \"text\": {\"content\": \"$text\"}}]}}"
        elif [[ "$line" == "---" ]] || [[ "$line" == "--- "* ]] || [[ "$line" =~ ^---+$ ]]; then
            block_json="{\"type\": \"divider\", \"divider\": {}}"
        elif [[ -n "$line" ]]; then
            local text
            text=$(echo "$line" | jq -Rs '.' | sed 's/^"//;s/"$//')
            block_json="{\"type\": \"paragraph\", \"paragraph\": {\"rich_text\": [{\"type\": \"text\", \"text\": {\"content\": \"$text\"}}]}}"
        fi

        if [[ -n "$block_json" ]]; then
            if [[ "$first" == false ]]; then blocks+=","; fi
            blocks+="$block_json"
            first=false
        fi
    done < "$file_path"

    blocks+="]"

    append_blocks "$page_id" "$blocks"
}

# 追加标题
append_heading() {
    local page_id="$1"
    local level="$2"
    local text="$3"

    if [[ -z "$page_id" ]] || [[ -z "$level" ]] || [[ -z "$text" ]]; then
        echo -e "${RED}错误: 请提供页面 ID、标题级别(1-3)和标题文本${NC}"
        return 1
    fi

    local escaped_text
    escaped_text=$(echo "$text" | jq -Rs '.' | sed 's/^"//;s/"$//')

    append_blocks "$page_id" "[{
        \"type\": \"heading_$level\",
        \"heading_$level\": {
            \"rich_text\": [{ \"type\": \"text\", \"text\": { \"content\": \"$escaped_text\" } }]
        }
    }]"
}

# 追加列表
append_list() {
    local page_id="$1"
    local items="$2"

    if [[ -z "$page_id" ]] || [[ -z "$items" ]]; then
        echo -e "${RED}错误: 请提供页面 ID 和列表项（用 | 分隔）${NC}"
        return 1
    fi

    local blocks="["
    local first=true

    IFS='|' read -ra ITEMS <<< "$items"
    for item in "${ITEMS[@]}"; do
        local escaped_item
        escaped_item=$(echo "$item" | jq -Rs '.' | sed 's/^"//;s/"$//')
        if [[ "$first" == false ]]; then blocks+=","; fi
        blocks+="{
            \"type\": \"bulleted_list_item\",
            \"bulleted_list_item\": {
                \"rich_text\": [{ \"type\": \"text\", \"text\": { \"content\": \"$escaped_item\" } }]
            }
        }"
        first=false
    done

    blocks+="]"

    append_blocks "$page_id" "$blocks"
}

# 追加待办项
append_todo() {
    local page_id="$1"
    local text="$2"
    local checked="${3:-false}"

    if [[ -z "$page_id" ]] || [[ -z "$text" ]]; then
        echo -e "${RED}错误: 请提供页面 ID 和待办内容${NC}"
        return 1
    fi

    local escaped_text
    escaped_text=$(echo "$text" | jq -Rs '.' | sed 's/^"//;s/"$//')

    append_blocks "$page_id" "[{
        \"type\": \"to_do\",
        \"to_do\": {
            \"rich_text\": [{ \"type\": \"text\", \"text\": { \"content\": \"$escaped_text\" } }],
            \"checked\": $checked
        }
    }]"
}

# 追加代码块
append_code() {
    local page_id="$1"
    local language="$2"
    local code="$3"

    if [[ -z "$page_id" ]] || [[ -z "$code" ]]; then
        echo -e "${RED}错误: 请提供页面 ID 和代码内容${NC}"
        return 1
    fi

    # Notion 支持的语言映射
    local lang_lower
    lang_lower=$(echo "$language" | tr '[:upper:]' '[:lower:]')

    local escaped_code
    escaped_code=$(echo "$code" | jq -Rs '.' | sed 's/^"//;s/"$//')

    append_blocks "$page_id" "[{
        \"type\": \"code\",
        \"code\": {
            \"language\": \"$lang_lower\",
            \"rich_text\": [{ \"type\": \"text\", \"text\": { \"content\": \"$escaped_code\" } }]
        }
    }]"
}

# 追加分割线
append_divider() {
    local page_id="$1"

    if [[ -z "$page_id" ]]; then
        echo -e "${RED}错误: 请提供页面 ID${NC}"
        return 1
    fi

    append_blocks "$page_id" "[{ \"type\": \"divider\", \"divider\": {} }]"
}

# 显示帮助
show_help() {
    echo -e "${BLUE}Notion API 工具${NC}\n"
    echo "用法: $0 <command> [args]\n"
    echo -e "${YELLOW}读取命令:${NC}"
    echo "  search <query>              搜索页面（不提供 query 则列出所有）"
    echo "  list                        列出所有可访问的页面"
    echo "  get <page_id>               获取页面内容（格式化输出）"
    echo "  raw <page_id>               获取页面原始 JSON 数据"
    echo ""
    echo -e "${YELLOW}写入命令:${NC}"
    echo "  create <parent_id> <title>              在父页面下创建子页面"
    echo "  append <page_id> <content>              追加文本段落"
    echo "  append-file <page_id> <file_path>       从文件追加内容（支持 Markdown）"
    echo "  append-heading <page_id> <level> <text> 追加标题（level: 1-3）"
    echo "  append-list <page_id> <item1|item2|...> 追加无序列表（用 | 分隔）"
    echo "  append-todo <page_id> <text> [checked]  追加待办项（checked: true/false）"
    echo "  append-code <page_id> <lang> <code>     追加代码块"
    echo "  append-divider <page_id>                追加分割线"
    echo ""
    echo -e "${YELLOW}示例:${NC}"
    echo "  $0 search Holo"
    echo "  $0 get 30133debccf880f387f3c13f36b53462"
    echo "  $0 create 30133debccf880f387f3c13f36b53462 '新功能计划'"
    echo "  $0 append 30133debccf880f387f3c13f36b53462 '这是一段新内容'"
    echo "  $0 append-heading 30133debccf880f387f3c13f36b53462 2 '二级标题'"
    echo "  $0 append-list 30133debccf880f387f3c13f36b53462 '项目1|项目2|项目3'"
    echo ""
    echo -e "${YELLOW}环境变量:${NC}"
    echo "  NOTION_API_KEY    Notion API 密钥（默认已配置）"
}

# 主入口
case "${1:-}" in
    # 读取命令
    search)
        search_pages "$2"
        ;;
    list)
        list_all
        ;;
    get)
        get_page "$2"
        ;;
    raw)
        get_raw "$2"
        ;;
    # 写入命令
    create)
        create_page "$2" "$3"
        ;;
    append)
        append_text "$2" "$3"
        ;;
    append-file)
        append_file "$2" "$3"
        ;;
    append-heading)
        append_heading "$2" "$3" "$4"
        ;;
    append-list)
        append_list "$2" "$3"
        ;;
    append-todo)
        append_todo "$2" "$3" "$4"
        ;;
    append-code)
        append_code "$2" "$3" "$4"
        ;;
    append-divider)
        append_divider "$2"
        ;;
    -h|--help|help)
        show_help
        ;;
    *)
        show_help
        exit 1
        ;;
esac
