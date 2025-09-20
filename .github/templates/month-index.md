---
title: "{{YEAR}}-{{MONTH}}"
weight: {{WEIGHT}}
breadcrumbs: false
sidebar:
  open: true
---

<div class="newspaper-month-header border-b-4 border-double border-gray-900 dark:border-gray-100 pb-6 mb-8">
  <div class="text-center">
    <h1 class="page-title text-4xl md:text-5xl font-bold font-serif mb-2 text-gray-900 dark:text-gray-100">
      {{YEAR}}年{{MONTH}}月
    </h1>
    <div class="sub-head-en text-lg md:text-xl text-gray-600 dark:text-gray-400 italic mb-4">
      AI DAILY BRIEFING ARCHIVE
    </div>
    <div class="lede-cn text-gray-600 dark:text-gray-400">
      本月收录 AI 行业重要动态，按日期归档整理
    </div>
  </div>
</div>

<div class="newspaper-daily-list hx-mt-12">
  <h2 class="section-title text-2xl font-bold mb-6 font-serif flex items-center">
    <span class="mr-3">📰</span>
    本月日报
    <span class="en ml-auto text-sm font-normal text-gray-500">
      Daily AI Briefings
    </span>
  </h2>
  
  <div class="newspaper-articles-grid">
    {{CONTENT}}
  </div>
</div>