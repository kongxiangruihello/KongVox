import SwiftUI

struct BrandIcon: View {
    var size: CGFloat = 72
    var body: some View {
        Group {
            if let path = Bundle.main.url(forResource: "KongVox-icon", withExtension: "png"), let icon = NSImage(contentsOf: path) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else { Image(systemName: "book.and.wrench.fill").resizable().scaledToFit().foregroundStyle(.indigo) }
        }.frame(width: size, height: size)
    }
}
struct WelcomeView: View {
    let configure: () -> Void
    let start: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 18) {
                BrandIcon(size: 100)
                VStack(alignment: .leading, spacing: 8) {
                    Text("欢迎使用 KongVox").font(.system(size: 30, weight: .bold))
                    Text("让整篇文字，自然开口。").font(.title3).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 20) {
                step("1", "连接配音服务", "在服务设置中选择服务和模型，填入自己的 API Key。密钥保存在 Mac 钥匙串。")
                step("2", "粘贴全文，先听开头", "确认声音和语速后生成全文。已生成且设置未变的开头会复用。")
                step("3", "检查成品，一次导出", "拖动进度条检查内容，导出完整音频，或包含音频和字幕的组合包。")
            }.padding(22).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
            Text("配音会按你的服务商账户计费；本地播放与导出不调用合成接口。升级后，macOS 可能要求重新授权钥匙串访问。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("KongVox 0.11.2 · macOS").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("直接开始", action: start).controlSize(.large)
                Button("配置配音服务", action: configure).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }.padding(32).frame(width: 650)
            .background(LinearGradient(colors: [Color.indigo.opacity(0.10), Color(nsColor: .windowBackgroundColor)], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
    func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.headline).foregroundStyle(.indigo).frame(width: 28, height: 28).background(.indigo.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
