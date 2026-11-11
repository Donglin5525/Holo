"""东林 Mac 同步库（CloudKit 开发库镜像）只读分析：来源信息密度 / 11 月新记忆依据的来源时间 / 重复 / 引文长度。
只输出计数，不输出任何正文。

用法（先复制一份再查，不碰原库）：
  D="$HOME/Library/Group Containers/group.com.tangyuxuan.holo-app"
  mkdir -p /tmp/holo-mx/macdb && cp "$D"/HoloDataModel.sqlite* /tmp/holo-mx/macdb/
  python3 -I mac_store_analysis.py /tmp/holo-mx/macdb/HoloDataModel.sqlite
"""
import collections, datetime, hashlib, json, re, sqlite3, sys, uuid

path = sys.argv[1]
db = sqlite3.connect(f'file:{path}?mode=ro', uri=True)
EPOCH = 978307200  # Core Data 时间基准 2001-01-01
q = lambda sql, *a: db.execute(sql, a).fetchall()

print('== 来源规模与信息密度')
print('想法(未删未归档)', q("select count(*) from ZTHOUGHT where ZDELETEDAT is null and coalesce(ZISARCHIVED,0)=0")[0][0])
print('账单', q("select count(*) from ZTRANSACTION where ZDELETEDAT is null")[0][0],
      '备注长度分布', q("""select case when length(trim(coalesce(ZNOTE,'')||coalesce(ZREMARK,'')))=0 then '0'
        when length(trim(coalesce(ZNOTE,'')||coalesce(ZREMARK,'')))<=4 then '1-4' when length(trim(coalesce(ZNOTE,'')||coalesce(ZREMARK,'')))<=10 then '5-10' else '>10' end b, count(*)
        from ZTRANSACTION where ZDELETEDAT is null group by b"""))
print('打卡', q("select count(*), sum(case when length(trim(coalesce(ZNOTE,'')))>0 then 1 else 0 end) from ZHABITRECORD where ZDELETEDAT is null")[0], '(总数, 有备注)')
print('任务', q("select count(*), sum(case when length(trim(coalesce(ZDESC,'')))>0 then 1 else 0 end) from ZTODOTASK where ZDELETEDAT is null and coalesce(ZDELETEDFLAG,0)=0")[0], '(总数, 有描述)')
print('聊天(用户消息)', q("select count(*), sum(case when length(ZCONTENT)<=20 then 1 else 0 end), round(avg(length(ZCONTENT))) from ZCHATMESSAGE where ZDELETEDAT is null and ZROLE='user'")[0], '(总数, ≤20字, 平均字数)')
print('记忆按状态', q("select ZSTATE, count(*) from ZHOLOMEMORYRECORDMO where ZDELETEDAT is null group by ZSTATE"))

# 来源 ID → 时间
def U(z):
    return str(uuid.UUID(bytes=bytes(z))).upper() if isinstance(z, (bytes, memoryview)) else str(z).upper()
src = {}
for zid, t in q("select ZID, ZUPDATEDAT from ZTRANSACTION"): src['finance:' + U(zid)] = t
for zid, t in q("select ZID, ZUPDATEDAT from ZTODOTASK"): src['task:' + U(zid)] = t
for zid, t in q("select ZID, ZCREATEDAT from ZHABITRECORD"): src['habit-checkin:' + U(zid)] = t
for zid, t in q("select ZID, ZTIMESTAMP from ZCHATMESSAGE"): src['conversation:' + U(zid)] = t
for zid, t in q("select ZID, ZUPDATEDAT from ZTHOUGHT"): src[U(zid)] = t
pat = re.compile(r'"sourceID"\s*:\s*"((?:habit-checkin|finance|task|habit|conversation|goal):[0-9A-Fa-f-]{36}|[0-9A-Fa-f-]{36})"')
norm = lambda s: (s.split(':', 1)[0] + ':' + s.split(':', 1)[1].upper()) if ':' in s else s.upper()

print('\n== 11 月新建的个人情境记忆：依据来源的时间（按月计数）')
cut = datetime.datetime(2026, 11, 1).timestamp() - EPOCH
agg, n = collections.Counter(), 0
for (blob,) in q("select ZRECORDDATA from ZHOLOMEMORYRECORDMO where ZDELETEDAT is null and ZCREATEDAT >= ?", cut):
    text = bytes(blob).decode('utf-8', 'ignore')
    if '"personalContext"' not in text:
        continue
    n += 1
    for sid in set(pat.findall(text)):
        k = norm(sid); t = src.get(k)
        if t is not None:
            agg[(k.split(':')[0] if ':' in k else 'thought', datetime.datetime.utcfromtimestamp(t + EPOCH).strftime('%Y-%m'))] += 1
print('记录数', n)
for k in sorted(agg):
    print(' ', k[0], k[1], agg[k])

print('\n== 待确认+已生效 个人情境记忆：重复 / 依据条数 / 引文长度')
exact, skel, nb, ql = collections.Counter(), collections.Counter(), [], []
for (blob,) in q("select ZRECORDDATA from ZHOLOMEMORYRECORDMO where ZDELETEDAT is null and ZSTATE in ('candidate','active')"):
    d = json.loads(bytes(blob).decode('utf-8'))
    pc = d.get('personalContext') or {}
    pc = pc.get('v1', pc) if isinstance(pc, dict) else None
    if not pc or 'statement' not in pc:
        continue
    s = pc['statement']
    exact[hashlib.sha1(s.encode()).hexdigest()] += 1
    sk = re.sub(r'[0-9０-９一二三四五六七八九十两]+', '#', s)
    skel[hashlib.sha1(re.sub(r'[，。、“”「」（）()：:；;！!？?\s]', '', sk).encode()).hexdigest()] += 1
    b = pc.get('basis') or []
    nb.append(len(b)); ql.extend(len(x.get('quote') or '') for x in b)
tot = sum(exact.values()); nb.sort(); ql.sort()
print('记录', tot, '一字不差重复(多出的条数)', tot - len(exact), '最大句式组', sorted(skel.values(), reverse=True)[:6])
print('每条依据数 中位', nb[len(nb) // 2], 'P90', nb[int(len(nb) * .9)], '最大', nb[-1])
print('引文字数 中位', ql[len(ql) // 2], 'P90', ql[int(len(ql) * .9)], '最大', ql[-1])

print('\n== 个人情境批次回执（含其他同 iCloud 设备同步来的）')
for row in q("""select date(ZCOMPLETEDAT+?+8*3600,'unixepoch') d, count(*) from ZHOLOMEMORYOBSERVATIONRUNMO
               where ZOBSERVATIONKEY like 'pc-batch-%' and ZOBSERVATIONKEY not like '%#%' and ZCOMPLETEDAT >= ? group by d""", EPOCH, cut):
    print(' ', row)
