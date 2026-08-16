# 手机远程访问部署

本地地址 `127.0.0.1` 只对当前电脑有效。公网版本由两部分组成：

1. GitHub Pages 发布 `remote-system/web` 静态网页。
2. Supabase Free 保存批量提交、状态和处理结果。

## Supabase

1. 在 Supabase 创建一个 Free 项目。
2. 在 SQL Editor 按顺序执行 `remote-system/supabase/migrations/0001_remote_tasks.sql` 和 `remote-system/supabase/migrations/0002_daily_invitation_codes.sql`。
3. 记录 Project URL、anon public key 和 service_role key。

执行第二个迁移后，系统会立即生成当天的 10 个随机邀请码，并每天 00:00（Asia/Shanghai）自动生成 10 个新码。邀请码只允许注册成功一次；查看和手动追加邀请码只在 Supabase SQL Editor 或 service-role 管理端进行，网页不会暴露邀请码列表。

service_role key 只放在 Windows Agent 的 `.env`，不能放入网页或 GitHub Pages。

## GitHub Pages

在仓库 Settings -> Secrets and variables -> Actions 添加：

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

然后运行 `Deploy remote web` workflow。部署完成后，GitHub Pages 会生成手机可访问的 HTTPS 地址。

当前公网预览地址：

`https://wzq522.github.io/welearn-remote/`

该地址目前可以直接用手机打开；在 Supabase 密钥配置完成前，注册、登录和提交按钮会保持禁用，这是为了避免把请求发送到不存在的后端。配置完成后，手机端先注册或登录，再提交和查看自己的任务。

也可以用 GitHub CLI 写入网页端两个密钥：

```sh
gh secret set SUPABASE_URL --repo WZQ522/welearn-remote
gh secret set SUPABASE_ANON_KEY --repo WZQ522/welearn-remote
```

写入后重新运行 `Deploy remote web` workflow。

## Windows Agent

在电脑端从发布包解压 Agent，复制 `.env.example` 为 `.env`，填写：

```dotenv
SUPABASE_URL=https://PROJECT.supabase.co
SUPABASE_SERVICE_ROLE_KEY=服务端密钥
PROCESSOR_COMMAND_JSON=["my-program.exe"]
```

运行 `check_agent.bat` 验证配置，再运行 `run_agent.bat`。电脑关机时提交会留在 Supabase，重新开机后 Agent 会自动领取。

## 当前限制

没有 Supabase 项目和密钥时，网页只能显示界面，不能真正提交云端任务。GitHub Pages 本身只托管静态文件，不能替代任务数据库和 Agent 队列。
