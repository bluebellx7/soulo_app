import Foundation
import Network

/// Runs on the test device, so both browsers receive identical localhost pages.
final class BrowserBenchmarkHTTPFixture: @unchecked Sendable {
    struct Mark: Codable {
        let browser: String
        let phase: String
        let elapsed: Double
        let persisted: Bool
        let at: Double
        let adFiltering: Bool?
        let scrollOffset: Double?
    }
    private let queue=DispatchQueue(label:"soulo.browser.benchmark.http")
    private let listener: NWListener
    private var marks:[Mark]=[]
    private var connections:[NWConnection]=[]
    init() throws { listener=try NWListener(using:.tcp,on:.any) }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler={ [weak self] state in
                guard let self else{return}
                if case .ready=state,let port=listener.port {
                    continuation.resume(returning:URL(string:"http://127.0.0.1:\(port.rawValue)")!)
                } else if case .failed(let error)=state {continuation.resume(throwing:error)}
            }
            listener.newConnectionHandler={ [weak self] connection in
                guard let self else{return};connections.append(connection);connection.start(queue:queue);receive(connection)
            }
            listener.start(queue:queue)
        }
    }
    func stop(){listener.cancel();queue.sync{connections.forEach{$0.cancel()};connections=[]}}
    func events(_ browser:String,_ phase:String)->[Mark]{queue.sync{marks.filter{$0.browser==browser&&$0.phase==phase}}}
    func allEvents()->[Mark]{queue.sync{marks}}
    private func receive(_ connection:NWConnection){
        connection.receive(minimumIncompleteLength:1,maximumLength:65536){ [weak self] data,_,_,_ in
            guard let self,let data,let request=String(data:data,encoding:.utf8),let line=request.components(separatedBy:"\r\n").first,
                  let target=line.split(separator:" ").dropFirst().first,
                  let url=URLComponents(string:"http://localhost"+target) else{connection.cancel();return}
            let parameters=Dictionary((url.queryItems ?? []).map{($0.name,$0.value ?? "")},uniquingKeysWith:{_,last in last})
            if url.path=="/_mark"{
                marks.append(Mark(browser:parameters["browser"] ?? "",phase:parameters["phase"] ?? "",elapsed:Double(parameters["elapsed"] ?? "") ?? 0,persisted:parameters["persisted"]=="true",at:Date().timeIntervalSince1970,adFiltering:parameters["adFiltering"].flatMap { $0=="true" ? true : $0=="false" ? false : nil },scrollOffset:parameters["scrollOffset"].flatMap(Double.init)))
                send(connection,"",mime:"text/plain",cacheControl:"no-store");return
            }
            if url.path=="/poster.svg"{send(connection,"<svg xmlns='http://www.w3.org/2000/svg' width='320' height='180'><rect width='320' height='180' fill='#e9edf4'/><circle cx='160' cy='90' r='28' fill='#bdc9dc'/></svg>",mime:"image/svg+xml");return}
            send(connection,page(destination:url.path=="/destination",browser:parameters["browser"] ?? "unknown",selection:url.path=="/selection",history:url.path=="/history"),mime:"text/html;charset=utf-8")
        }
    }
    private func send(_ connection:NWConnection,_ body:String,mime:String,cacheControl:String="max-age=3600"){
        let data=Data(body.utf8),header="HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nCache-Control: \(cacheControl)\r\nConnection: close\r\n\r\n"
        connection.send(content:Data(header.utf8)+data,completion:.contentProcessed{_ in connection.cancel()})
    }
    private func page(destination:Bool,browser:String,selection:Bool=false,history:Bool=false)->String{
        let hold=selection ? " style='user-select:none!important;-webkit-user-select:none!important'" : ""
        let content=destination ? "<h1>Article destination</h1><p>The same result document for both browsers.</p>" : "<h1\(hold)>Salt search benchmark</h1><a id='result' href='/destination?browser=\(browser)'>Open benchmark result</a><br><a id='restart' href='/source?browser=\(browser)'>Reload benchmark page</a>"+(0..<100).map{i in
            "<article class='c-result' tpl='www_index'><h2>盐焗食谱 \(i)</h2><p>传统做法、火候和烹饪步骤，浏览器性能对照内容。</p>"+(i%5==0 ? "<video muted playsinline preload='none' poster='/poster.svg' style='width:320px;height:180px'></video>" : "")+(history ? "<a href='/destination?browser=\(browser)'>Open result at \(i)</a>" : "")+"</article>"
        }.joined()
        return """
        <!doctype html><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Salt search benchmark</title>
        <style>body{margin:0;padding:24px;color:#202124;background:white;font:17px -apple-system,sans-serif}article{margin:20px 0;padding:18px;border-bottom:1px solid #eee}h2{font-size:21px}a{display:inline-block;padding:12px 0;color:#174ea6}</style>
        \(content)
        <script>
        const browser=\(String(reflecting:browser)),destination=\(destination);
        function report(phase,elapsed,persisted=false){fetch('/_mark?'+new URLSearchParams({browser,phase,elapsed,persisted,scrollOffset:scrollY,adFiltering:window.__souloAdBlockConfig?.cosmeticEnabled ?? "missing"}),{keepalive:true,cache:'no-store'}).catch(()=>{})}
        addEventListener('pageshow',event=>requestAnimationFrame(()=>requestAnimationFrame(()=>{
          if(destination) report('result',Date.now()-Number(sessionStorage.getItem('tap')||Date.now()),event.persisted);
          else if(event.persisted || performance.getEntriesByType('navigation')[0]?.type==='back_forward')report('back',Date.now()-Number(sessionStorage.getItem('leaving')||Date.now()),event.persisted);
          else report('ready',performance.now());
        })));
        if(\(history))addEventListener('pageshow',event=>{
          if(!event.persisted)return;
          const expected=Number(sessionStorage.getItem('source-scroll')),started=performance.now();
          let timer;
          const cleanup=()=>{removeEventListener('scroll',check);clearTimeout(timer)};
          const check=()=>{
            if(Math.abs(scrollY-expected)>2)return;
            cleanup();report('position-restored',performance.now()-started,true);
          };
          addEventListener('scroll',check,{passive:true});
          timer=setTimeout(cleanup,5000);requestAnimationFrame(check);
        });
        document.getElementById('result')?.addEventListener('click',()=>sessionStorage.setItem('tap',Date.now()));
        if(\(history))document.addEventListener('click',event=>{
          if(event.target.closest('a')?.pathname!=='/destination')return;
          sessionStorage.setItem('tap',Date.now());sessionStorage.setItem('source-scroll',scrollY);report('leaving-source',0);
        });
        addEventListener('pagehide',()=>{if(destination)sessionStorage.setItem('leaving',Date.now())});
        </script>
        """
    }
}
