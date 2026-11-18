import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig } from '@rspack/cli'
import { rspack, type Configuration } from '@rspack/core'

const dev = process.env.NODE_ENV !== 'production'
const targets = ['chrome >= 105', 'edge >= 105', 'safari >= 16', 'firefox >= 110']
const root = path.dirname(fileURLToPath(import.meta.url))
// package.json 的 version 只是**网页示例的版本**（0.1.x），和 App 真实版本无关：
// App 的发版版本号只认 android/app/build.gradle 的 versionName / versionCode。
const { version: pkgVersion } = JSON.parse(
  readFileSync(new URL('./package.json', import.meta.url), 'utf8')
) as { version: string }

const readGradle = (): string => {
  try {
    return readFileSync(path.resolve(root, 'android/app/build.gradle'), 'utf8')
  } catch {
    return ''
  }
}

/** Android versionCode（诊断上报用，读不到记 0） */
const readVersionCode = (): number => Number(/versionCode\s+(\d+)/.exec(readGradle())?.[1] ?? 0) || 0

/** App 版本名（诊断上报用，读不到回退 package.json） */
const readVersionName = (): string => /versionName\s+"([^"]+)"/.exec(readGradle())?.[1] ?? pkgVersion

/**
 * 构建期注入的版本号优先级：环境变量 APP_VERSION > gradle versionName > package.json。
 * 环境变量留给出包脚本（CI 传 tag 名）覆盖，本地构建直接吃 gradle —— 这是唯一权威来源。
 */
const appVersion = process.env.APP_VERSION?.trim() || readVersionName()

/**
 * 产物自述文件（build-info.json）：写进输出目录的 variant / main hash / 构建时间 / 版本。
 *
 * 为什么需要：测试（tests/helpers/env.mjs）要能判断「dist 里这份产物是标准包还是内测包、
 * 是不是比源码旧、端口上 serve 的是不是同一份」。没有它就只能靠猜，于是出现
 * 「拿标准包跑内测用例」「5181 端口 serve 的是别的分支产物」这类假红（Issue #19）。
 * 只写一个静态 JSON，不影响运行时代码与部署。
 */
const buildInfoPlugin = (variant: 'standard' | 'internal', version: string, outPath: string) => ({
  apply(compiler: {
    hooks: { afterEmit: { tapAsync: (name: string, handler: (compilation: unknown, callback: () => void) => void) => void } }
  }) {
    compiler.hooks.afterEmit.tapAsync('BuildInfoPlugin', (_compilation: unknown, callback: () => void) => {
      try {
        const out = path.resolve(root, outPath)
        const mainFile =
          readdirSync(path.join(out, 'static', 'js')).find((name) => /^main\.[a-z0-9]+\.js$/.test(name)) ?? ''
        writeFileSync(
          path.join(out, 'build-info.json'),
          `${JSON.stringify(
            {
              variant,
              main: mainFile,
              hash: /^main\.([a-z0-9]+)\.js$/.exec(mainFile)?.[1] ?? null,
              version,
              builtAt: new Date().toISOString(),
            },
            null,
            2
          )}\n`
        )
      } catch {
        // 写不出来不影响构建（测试会按「没有自述文件」降级判断）
      }
      callback()
    })
  },
})

const cssLoader = {
  loader: 'builtin:lightningcss-loader',
  options: { targets },
}

type ConfigOptions = {
  /** 公开 API 的地址，注入为 __API_ORIGIN__ */
  apiOrigin?: string
  /**
   * 内测构建：注入 __INTERNAL_BUILD__=true，服务地址 / 模型 / 服务类型由
   * src/services/api/internalBuild.ts 的常量钉死（设置页不再暴露这三项的编辑入口）。
   * 默认 false：正式构建行为与之前完全一致。
   */
  internalBuild?: boolean
  /** 输出目录（默认 dist；cap sync 只认 dist） */
  outputPath?: string
  /** 开发服务器配置，支持本地接口代理 */
  devServer?: Configuration['devServer']
}

/** 创建构建配置，支持自定义 API 地址和开发服务器选项 */
export const createConfig = ({
  apiOrigin = 'https://api.deepseek.com',
  internalBuild = process.env.INTERNAL_BUILD === '1',
  // 默认 dist；测试要在不影响部署产物（dist）的前提下另起一份标准构建时用 DIST_OUT 指定
  outputPath = process.env.DIST_OUT || 'dist',
  devServer,
}: ConfigOptions = {}): Configuration => ({
  mode: dev ? 'development' : 'production',
  entry: './src/main.tsx',
  output: {
    path: path.resolve(root, outputPath),
    // 运行时按当前脚本地址推导资源路径，file:// 下异步 chunk、字体都按相对位置加载
    publicPath: 'auto',
    filename: 'static/js/[name].[contenthash:8].js',
    chunkFilename: 'static/js/async/[name].[contenthash:8].js',
    cssFilename: 'static/css/[name].[contenthash:8].css',
    cssChunkFilename: 'static/css/async/[name].[contenthash:8].css',
    assetModuleFilename: 'static/media/[name].[contenthash:8][ext]',
    clean: true,
  },
  devtool: dev ? 'cheap-module-source-map' : false,
  // 开发模式预编译异步模块，保持首次加载代码高亮和公式时的页面状态
  lazyCompilation: false,
  resolve: {
    extensions: ['.tsx', '.ts', '.js'],
    // 将 .js 导入路径解析到同名 .ts、.tsx 或 .js 文件
    extensionAlias: { '.js': ['.ts', '.tsx', '.js'] },
  },
  module: {
    // CSS Modules 使用默认导出：`import styles from './x.module.css'`
    parser: { 'css/module': { namedExports: false } },
    generator: { 'css/module': { localIdentName: '[local]-[hash:6]' } },
    rules: [
      { test: /\.module\.css$/, type: 'css/module', use: [cssLoader] },
      { test: /\.css$/, exclude: /\.module\.css$/, type: 'css', use: [cssLoader] },
      {
        test: /\.(j|t)sx?$/,
        exclude: /[\\/]node_modules[\\/]/,
        loader: 'builtin:swc-loader',
        options: {
          jsc: {
            parser: { syntax: 'typescript', tsx: true },
            transform: { react: { runtime: 'automatic', development: dev } },
            externalHelpers: true,
          },
          env: { targets },
        },
        type: 'javascript/auto',
      },
      { test: /\.(woff2?|ttf)$/, type: 'asset/resource' },
    ],
  },
  plugins: [
    // 经典 defer 脚本支持 file:// 页面的资源加载
    new rspack.HtmlRspackPlugin({
      template: './src/index.html',
      scriptLoading: 'defer',
      meta: { 'application-version': appVersion },
    }),
    new rspack.DefinePlugin({
      __API_ORIGIN__: JSON.stringify(apiOrigin),
      __INTERNAL_BUILD__: JSON.stringify(internalBuild),
      __APP_VERSION__: JSON.stringify(appVersion),
      __APP_VERSION_CODE__: JSON.stringify(readVersionCode()),
    }),
    buildInfoPlugin(internalBuild ? 'internal' : 'standard', appVersion, outputPath),
    new rspack.CopyRspackPlugin({
      patterns: [{ from: path.resolve(root, 'LICENSE'), to: 'LICENSE', toType: 'file' }],
    }),
  ],
  performance: { hints: false },
  devServer: { port: 8090, ...devServer },
})

// eslint-disable-next-line import/no-default-export
export default defineConfig(createConfig())
