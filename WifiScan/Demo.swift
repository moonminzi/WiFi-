import Foundation

/// 화면 스크린샷용 데모 상태(.github/workflows/ui-shots.yml). Debug 빌드에서만 켜진다.
/// 시뮬레이터에서 `-nagoDemo connected`처럼 실행 인자로 넘기면 서버 없이 그 상태를 그린다.
/// - idle / connecting / connected / failed
enum Demo {
    #if DEBUG
    static let state = UserDefaults.standard.string(forKey: "nagoDemo")
    #else
    static let state: String? = nil
    #endif

    static var on: Bool { state != nil }
    #if DEBUG
    /// 스크린샷: 화면 맨 아래로 내려서 찍기
    static let scrollToEnd = UserDefaults.standard.bool(forKey: "nagoScrollEnd")
    #else
    static let scrollToEnd = false
    #endif
    #if DEBUG
    /// 스크린샷: 이 임시 나라 칸을 누르고 있는 것처럼 말풍선을 띄워 둔다(`-nagoPeek de`)
    static let peek = UserDefaults.standard.string(forKey: "nagoPeek").flatMap(VPNRegion.init(rawValue:))
    /// 스크린샷: 데모에서 고를 나라(없으면 jp, `-nagoRegion de`)
    static let region = UserDefaults.standard.string(forKey: "nagoRegion").flatMap(VPNRegion.init(rawValue:))
    /// 스크린샷: 맨 위에서 이만큼(pt) 아래로 당긴 모습(`-nagoPull 90`)
    static let pull = CGFloat(UserDefaults.standard.double(forKey: "nagoPull"))
    #else
    static let peek: VPNRegion? = nil
    static let region: VPNRegion? = nil
    static let pull: CGFloat = 0
    #endif
    static var connected: Bool { state == "connected" }
    /// 데모 연결이 붙은 시각(12분 34초 전)
    static let since = Date().addingTimeInterval(-754)

    /// 연결 중 화면의 진행 단계(앞에서부터 몇 초 전에 찍혔는지)
    static let steps: [(ago: Double, text: String)] = [
        (24.6, "jp: checking server…"),
        (21.2, "jp: booting…"),
        (4.1, "jp: up, waiting for ike…"),
    ]

    static let linkStats = "hs 12s ago · rx 48.2 MiB · tx 3.1 MiB"

    /// dash 탭 예시 데이터
    static let dash: DashData? = {
        let json = """
        {"ts":"2026-10-24 19:41","nodes":[
         {"code":"kr","city":"seoul","region":"ap-northeast-2","type":"t4g.small","state":"running","ip":"3.38.243.135","up":45120,"idle":12,"idleLimit":180,"ike":1,"leases":[],"load":"0.02","hours":412.5,"egressGB":38.4,"usd":6.81},
         {"code":"jp","city":"tokyo","region":"ap-northeast-1","type":"t4g.micro","state":"running","ip":"54.199.12.4","up":754,"idle":0,"idleLimit":30,"ike":0,"leases":[],"load":"0.11","hours":61.2,"egressGB":12.9,"usd":0.71},
         {"code":"us","city":"oregon","region":"us-west-2","type":"t4g.micro","state":"stopped","ip":null,"up":null,"idle":null,"idleLimit":null,"ike":0,"leases":[],"load":null,"hours":8.4,"egressGB":1.2,"usd":0.07},
         {"code":"uk","city":"london","region":"eu-west-2","type":"t4g.micro","state":"pending","ip":null,"up":null,"idle":null,"idleLimit":null,"ike":0,"leases":[],"load":null,"hours":3.1,"egressGB":0.4,"usd":0.03}],
        "peers":[
         {"n":"2","ip":"10.66.0.2","name":"iphone","adblock":true,"hsAgo":12,"rx":50540000,"tx":3250000,"ep":"211.36.1.9:51820"},
         {"n":"3","ip":"10.66.0.3","name":"ipad","adblock":false,"hsAgo":4210,"rx":1200000,"tx":340000,"ep":"211.36.1.9:41220"}],
        "hourly":[{"h":"08","gb":0.4},{"h":"09","gb":1.2},{"h":"10","gb":0.8},{"h":"11","gb":2.6},{"h":"12","gb":3.1},{"h":"13","gb":1.9},{"h":"14","gb":0.6},{"h":"15","gb":0.2},{"h":"16","gb":1.4},{"h":"17","gb":4.2},{"h":"18","gb":2.2},{"h":"19","gb":0.9}],
        "month":{"egressGB":52.9,"freeGB":100,"egressUSD":0,"fixedUSD":6.2,"usd":7.62}}
        """
        return try? JSONDecoder().decode(DashData.self, from: Data(json.utf8))
    }()
}
