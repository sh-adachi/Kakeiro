import SwiftUI

struct Institution: Identifiable {
    let name: String
    let kind: AccountKind
    var id: String { name }
    static let requested: [Institution] = [
        .init(name: "SBI証券", kind: .securities), .init(name: "楽天証券", kind: .securities),
        .init(name: "楽天銀行", kind: .bank), .init(name: "三井住友銀行", kind: .bank),
        .init(name: "三菱UFJ銀行", kind: .bank), .init(name: "ゆうちょ銀行", kind: .bank)
    ]
}

struct ConnectionsView: View {
    @State private var selected: Institution?
    @State private var addingCard = false
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    IconTile(symbol: "link")
                    Text("いつもの口座を、ひとつに。").font(.title3.bold())
                    Text("自動連携は未接続です。今は口座を手動で登録し、残高と明細を管理できます。").font(.subheadline).foregroundStyle(.secondary)
                    Label("自動連携は準備中", systemImage: "clock").font(.caption.weight(.semibold)).foregroundStyle(Palette.teal)
                }.padding(.vertical, 8)
            }
            Section("登録したい金融機関") {
                ForEach(Institution.requested) { institution in
                    Button { selected = institution } label: {
                        HStack(spacing: 12) {
                            IconTile(symbol: institution.kind.systemImage)
                            VStack(alignment: .leading, spacing: 4) { Text(institution.name).foregroundStyle(.primary); Text(institution.kind.title).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text("手動で登録").font(.caption).foregroundStyle(Palette.teal)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }.padding(.vertical, 4)
                    }.buttonStyle(.plain)
                }
            }
            Section { Button { addingCard = true } label: { Label("クレジットカードを登録", systemImage: "creditcard") } }
            Section("自動連携について") {
                Text("金融機関の名前を選んでもログインやデータ取得は始まりません。自動連携には連携サービスの利用契約と接続機能の追加が必要です。").font(.footnote).foregroundStyle(.secondary)
                Text("証券会社の追加認証や、楽天銀行の提携先制限によって、接続できない場合があります。").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("金融機関連携")
        .sheet(item: $selected) { AccountEditor(institution: $0.name, kind: $0.kind) }
        .sheet(isPresented: $addingCard) { AccountEditor(kind: .creditCard) }
    }
}
