---
type: regex
target: { source: file, path: test-result.txt }
pattern: '^PASS (\d+)/\1$'
weight: 2
---
