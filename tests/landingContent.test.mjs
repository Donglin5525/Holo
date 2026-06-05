import test from 'node:test'
import assert from 'node:assert/strict'

import {
  coreSections,
  legalLinks,
  productModules,
} from '../src/landing/content.js'

test('landing page exposes the five Holo product modules in order', () => {
  assert.deepEqual(
    productModules.map((module) => module.title),
    ['记账', '待办', '习惯', '想法', '健康'],
  )

  for (const module of productModules) {
    assert.ok(module.description.length > 0, `${module.title} should have description copy`)
    assert.ok(module.aiSignal.length > 0, `${module.title} should explain its HoloAI signal`)
  }
})

test('landing page includes the required HoloAI memory narrative sections', () => {
  assert.deepEqual(
    coreSections.map((section) => section.title),
    ['HoloAI', '记忆长廊', '记忆陪伴'],
  )

  assert.ok(
    coreSections.find((section) => section.title === 'HoloAI').description.includes('个人上下文'),
  )
  assert.ok(
    coreSections.find((section) => section.title === '记忆长廊').description.includes('时间线'),
  )
  assert.ok(
    coreSections.find((section) => section.title === '记忆陪伴').description.includes('陪伴'),
  )
})

test('landing page includes App Store review support and privacy links', () => {
  assert.deepEqual(
    legalLinks.map((link) => link.title),
    ['隐私政策', '用户支持', '数据删除', '健康数据说明'],
  )

  assert.ok(
    legalLinks.find((link) => link.title === '健康数据说明').description.includes('HealthKit'),
  )
})
