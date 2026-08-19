# 财务账单导入验证夹具

这些文件是本地模拟数据，不包含真实账户、交易号或个人信息。

| 文件 | 目的 |
|---|---|
| `wechat-bill.csv` | 微信固定模板、封面行、中文日期、全角表头、收支、不计收支、退款/关闭、逗号备注、同交易号重复、零金额 |
| `alipay-bill.csv` | 支付宝固定模板、交易号防重、收入、会计括号金额、退款/关闭、零金额 |
| `bank-statement.csv` | 银行未知模板、银行名提取、收入/支出分列、余额、流水号、逗号备注、零金额 |
| `outputs/finance-import-validation/bank-statement.xlsx` | Excel 多 Sheet、日期类型单元格、数字金额、银行账单转 CSV |
| `generic-edge-cases.csv` | UTF-8 BOM、英文表头、货币符号、千分位、空类型、非法日期、零金额、缺失金额、会计括号、引号内逗号 |
| `tsv-edge-cases.txt` | `.txt` 扩展名下的 TSV、紧凑日期、全角括号、欧式小数逗号、千分位、类型回退 |
| `outputs/finance-import-validation/bill-bundle.zip` | 无密码 ZIP，验证压缩包内账单文件提取 |

预期规则：退款/关闭/不计收支在账单扫描中跳过；零金额和缺失金额解析失败；非法日期扫描时产生阻断警告，未确认时不应进入普通转换结果。
