# Adapter Format Reference

Adapters are YAML files that define how to scrape a website. They are the core of AutoCLI's extensibility.

## File Locations

| Location | Priority | Description |
|----------|----------|-------------|
| `adapters/` (repo root) | Built-in | Embedded at compile time via `build.zig` |
| `~/.autocli/adapters/` | User | Loaded at runtime, overrides builtins |

**Naming conventions:**
- Nested: `adapters/{site}/{command}.yaml` → `autocli {site} {command}`
- Flat: `adapters/{site}_{command}.yaml` → `autocli {site} {command}`

## Schema

```yaml
# Required
site: string          # Site name (subcommand group)
command: string       # Command name (subcommand)
strategy: string      # Auth strategy: public | cookie | header | intercept | ui

# Optional
description: string   # Human-readable description
domain: string        # Base domain for browser pre-navigation
columns: string[]     # Output column names
browser: boolean      # Force browser mode (auto-detected from pipeline)
navigate_before:      # Pre-navigation behavior
  url: string         #   URL to navigate to before pipeline
  # or
  bool: boolean       #   true = navigate to domain, false = skip

# Arguments
args:                 # User-provided parameters
  - name: string      #   Argument name
    description: string
    required: boolean
    type: string      #   string | number | boolean
    default: any      #   Default value
    choices: string[] #   Allowed values

# Pipeline (required)
pipeline:             # Ordered list of steps
  - step_name: params
  - step_name: { param1: value1, param2: value2 }
```

## Auth Strategies

### `public`

No authentication required. The default strategy.

```yaml
strategy: public
```

### `cookie`

Attaches stored cookies to HTTP requests. Cookies are loaded from `~/.autocli/config.json`.

```yaml
strategy: cookie
```

### `header`

Injects `Authorization` header from stored tokens.

```yaml
strategy: header
```

### `intercept`

Captures cookies from a browser session by intercepting network requests. Requires browser mode.

```yaml
strategy: intercept
```

### `ui`

Requires user interaction in browser (e.g., login). Opens browser and waits for manual action.

```yaml
strategy: ui
```

## Complete Examples

### Simple HTTP API

```yaml
site: hackernews
command: top
description: Hacker News top stories
strategy: public
domain: news.ycombinator.com
columns:
  - title
  - url
  - points
  - author
  - comments
args:
  - name: limit
    description: Number of stories
    type: number
    default: 30
pipeline:
  - fetch: https://news.ycombinator.com
  - evaluate: |
      [...document.querySelectorAll('.athing')].slice(0, ${{ args.limit }}).map(row => {
        const titleEl = row.querySelector('.titleline a');
        const sub = row.nextElementSibling;
        return {
          title: titleEl?.textContent || '',
          url: titleEl?.href || '',
          points: parseInt(sub?.querySelector('.score')?.textContent) || 0,
          author: sub?.querySelector('.hnuser')?.textContent || '',
          comments: parseInt(sub?.querySelector('a:last-child')?.textContent) || 0,
        };
      })
  - select: data
```

### Browser-Based with Authentication

```yaml
site: bilibili
command: favorites
description: Bilibili user favorites
strategy: cookie
domain: www.bilibili.com
browser: true
columns:
  - title
  - bvid
  - author
args:
  - name: uid
    description: User ID
    required: true
    type: string
pipeline:
  - navigate: "https://space.bilibili.com/${{ args.uid }}/favlist"
  - wait:
      selector: ".fav-list"
  - evaluate: |
      [...document.querySelectorAll('.fav-list .item')].map(el => ({
        title: el.querySelector('.title')?.textContent?.trim() || '',
        bvid: el.querySelector('a')?.href?.match(/BV\\w+/)?.[0] || '',
        author: el.querySelector('.author')?.textContent?.trim() || '',
      }))
  - select: data
```

### REST API with Pagination

```yaml
site: github
command: repos
description: List user repositories
strategy: header
columns:
  - name
  - description
  - language
  - stars
args:
  - name: user
    description: GitHub username
    required: true
    type: string
  - name: limit
    type: number
    default: 30
pipeline:
  - fetch:
      url: "https://api.github.com/users/${{ args.user }}/repos"
      headers:
        Accept: application/vnd.github.v3+json
      params:
        sort: updated
        per_page: "${{ args.limit }}"
  - select: data
  - map:
      name: "${{ item.name }}"
      description: "${{ item.description | default: '' }}"
      language: "${{ item.language | default: 'N/A' }}"
      stars: "${{ item.stargazers_count }}"
```

### Download Pipeline

```yaml
site: bilibili
command: download
description: Download Bilibili video
strategy: cookie
browser: true
args:
  - name: bvid
    required: true
    type: string
pipeline:
  - navigate: "https://www.bilibili.com/video/${{ args.bvid }}"
  - wait:
      selector: "video"
  - evaluate: |
      document.querySelector('video')?.src || ''
  - select: data
  - download:
      url: "${{ data }}"
      output: "${{ args.bvid }}.mp4"
```

## Pipeline Step Quick Reference

| Step | Params | Returns | Browser? |
|------|--------|---------|----------|
| `fetch` | URL string or `{url, method, headers, body, params}` | Response body string | No |
| `navigate` | URL string or `{url, settleMs}` | void | Yes |
| `evaluate` | JS expression string | Evaluated value | Yes |
| `click` | CSS selector string | void | Yes |
| `type` | `{selector, text}` | void | Yes |
| `wait` | seconds or `{selector, text}` | void | Yes |
| `select` | Dot-path string | Extracted value (cloned) | No |
| `map` | Object with template values | Mapped array | No |
| `filter` | Template condition string | Filtered array | No |
| `sort` | Field string or `{by, order}` | Sorted array | No |
| `limit` | Number or template string | Truncated array | No |
| `download` | `{url, output}` | Downloaded file path | No |

## Current Adapter Count

The repository contains **345 YAML adapters** across **56 sites** including:

`antigravity`, `apple-podcasts`, `arxiv`, `barchart`, `bbc`, `bilibili`, `bloomberg`, `boss`, `chaoxing`, `chatgpt`, `chatwise`, `codex`, `coupang`, `ctrip`, `cursor`, `devto`, `discord`, `douban`, `doubao`, `facebook`, `google`, `grok`, `hackernews`, `huggingface`, `instagram`, `jike`, `jimeng`, `linkedin`, `linux-do`, `lobsters`, `medium`, `notion`, `reddit`, `reuters`, `sinablog`, `sinafinance`, `smzdm`, `stackoverflow`, `steam`, `substack`, `tiktok`, `twitter`, `v2ex`, `weibo`, `weixin`, `weread`, `wikipedia`, `xiaohongshu`, `xiaoyuzhou`, `xueqiu`, `yahoo-finance`, `yollomi`, `youtube`, `zhihu`
