/**
 * Makes test/fixtures/mediasoup_golden.json: what the real `mediasoup-client` (JavaScript) computes for the same inputs the Dart
 * port is given, so the Dart tests can require identical answers.
 *
 * Inputs are real: the capabilities and transport parameters of a running mediasoup router, and the SDP of a real Chrome. Nothing
 * from this folder ships in the package.
 *
 *   node tool/golden/generate.cjs        (needs Google Chrome; set CHROME_PATH if it is not in the usual place)
 */
const path = require('path');
const fs = require('fs');
const os = require('os');
const http = require('http');
const { spawn } = require('child_process');

const SDK = path.resolve(__dirname, '../../../../..');
const BACKEND = path.resolve(SDK, '../zapiack-backend');
const MSC = path.join(SDK, 'client/web/node_modules/mediasoup-client/lib');
const req = (p) => require(p);
const sdpTransform = req(path.join(SDK, 'client/web/node_modules/sdp-transform'));
const ortc = req(path.join(MSC, 'ortc'));
const { RemoteSdp } = req(path.join(MSC, 'handlers/sdp/RemoteSdp'));
const common = req(path.join(MSC, 'handlers/sdp/commonUtils'));
const unified = req(path.join(MSC, 'handlers/sdp/unifiedPlanUtils'));
const { Chrome111 } = req(path.join(MSC, 'handlers/Chrome111'));
const mediasoup = req(path.join(BACKEND, 'node_modules/mediasoup'));
const chrome = process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const clone = (x) => JSON.parse(JSON.stringify(x));

/** Runs a page in headless Chrome that posts one JSON result back. */
function inChrome(script, query = {}) {
  return new Promise((resolve, reject) => {
    const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'zapiack-golden-'));
    let proc;
    const server = http.createServer((rq, rs) => {
      if (rq.url === '/result' && rq.method === 'POST') {
        let b = '';
        rq.on('data', (c) => (b += c));
        return rq.on('end', () => {
          rs.writeHead(204).end();
          done(JSON.parse(b));
        });
      }
      rs.writeHead(200, { 'content-type': 'text/html' }).end(`<!doctype html><meta charset="utf-8"><script>
const q = new URLSearchParams(location.search);
const post = (r) => fetch('/result', { method: 'POST', body: JSON.stringify(r) });
(async () => { ${script} })().then(post, (e) => post({ error: String(e && e.message || e) }));
</script>`);
    });
    const timer = setTimeout(() => done({ error: 'chrome timed out' }), 60000);
    function done(r) {
      clearTimeout(timer);
      proc && proc.kill('SIGKILL');
      server.close();
      fs.rmSync(profile, { recursive: true, force: true });
      r.error ? reject(new Error(r.error)) : resolve(r);
    }
    server.listen(0, '127.0.0.1', () => {
      const qs = new URLSearchParams(query).toString();
      proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu', `--user-data-dir=${profile}`, '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--no-first-run', `http://127.0.0.1:${server.address().port}/?${qs}`], { stdio: 'ignore' });
    });
  });
}

const offers = () =>
  inChrome(`
const mk = () => new RTCPeerConnection({ iceServers: [], bundlePolicy: 'max-bundle', rtcpMuxPolicy: 'require' });
const ms = await navigator.mediaDevices.getUserMedia({ audio: true, video: true });
const a = ms.getAudioTracks()[0], v = ms.getVideoTracks()[0];
const out = {};
const st = () => new MediaStream();
// An offer for every order a call adds tracks in: a = microphone, v = camera or screen.
for (const seq of ['a', 'v', 'av', 'va', 'avv', 'vv', 'ava']) {
  const pc = mk();
  for (const k of seq) pc.addTransceiver(k === 'a' ? a : v, { direction: 'sendonly', streams: [st()], ...(k === 'v' ? { sendEncodings: [{ maxBitrate: 1200000 }] } : {}) });
  out[seq] = (await pc.createOffer()).sdp;
  pc.close();
}
out.audio = out.a;
out.audioVideo = out.av;
const pc = mk(); pc.addTransceiver('audio'); pc.addTransceiver('video', { sendEncodings: [{ scalabilityMode: 'L3T3' }] }); out.native = (await pc.createOffer()).sdp; pc.close();
return out;
`);

const answerTo = (remoteOffer) =>
  inChrome(`
const pc = new RTCPeerConnection({ iceServers: [], bundlePolicy: 'max-bundle', rtcpMuxPolicy: 'require' });
await pc.setRemoteDescription({ type: 'offer', sdp: q.get('offer') });
const ans = await pc.createAnswer();
pc.close();
return { answer: ans.sdp };
`, { offer: remoteOffer });

async function main() {
  const worker = await mediasoup.createWorker({ logLevel: 'error' });
  // codecs.ts is TypeScript: read the table out of it instead of compiling it.
  const src = fs.readFileSync(path.join(BACKEND, 'apps/media-core/src/app/codecs.ts'), 'utf8');
  const table = eval(src.slice(src.indexOf('= [') + 2, src.lastIndexOf('];') + 1));
  const router = await worker.createRouter({ mediaCodecs: table });
  const routerCaps = clone(router.rtpCapabilities);

  const transport = await router.createWebRtcTransport({ listenInfos: [{ protocol: 'udp', ip: '127.0.0.1' }, { protocol: 'tcp', ip: '127.0.0.1' }], enableUdp: true, enableTcp: true });
  const transportParams = clone({ iceParameters: transport.iceParameters, iceCandidates: transport.iceCandidates, dtlsParameters: transport.dtlsParameters });

  const sdps = await offers();

  // ───── sending: what the handler computes for an audio track, then a video track
  const nativeCaps = Chrome111.getLocalRtpCapabilities(sdpTransform.parse(sdps.native));
  const extended = ortc.getExtendedRtpCapabilities(clone(nativeCaps), clone(routerCaps), false);
  const recvCaps = ortc.getRecvRtpCapabilities(extended);

  const send = { transportParams, steps: [] };
  const remote = new RemoteSdp({ ...clone(transportParams), sctpParameters: undefined });
  const offer2 = sdpTransform.parse(sdps.audioVideo);
  if (offer2.extmapAllowMixed) remote.setSessionExtmapAllowMixed();
  let first = true;
  for (const [idx, kind, offerSdp, codecOptions] of [[0, 'audio', sdps.audioVideo, { opusDtx: true, opusFec: true }], [1, 'video', sdps.audioVideo, undefined]]) {
    const local = sdpTransform.parse(offerSdp);
    const extra = [{ uri: 'http://www.webrtc.org/experiments/rtp-hdrext/abs-capture-time', kind, direction: 'sendonly' }];
    const native = Chrome111.getLocalRtpCapabilities(local, extra);
    const ext = ortc.getExtendedRtpCapabilities(clone(native), clone(routerCaps), false);
    const params = ortc.getSendingRtpParameters(kind, ext);
    params.codecs = ortc.reduceCodecs(params.codecs, undefined);
    const remoteParams = ortc.getSendingRemoteRtpParameters(kind, ext);
    remoteParams.codecs = ortc.reduceCodecs(remoteParams.codecs, undefined);
    if (first) {
      const dtls = common.extractDtlsParameters({ sdpObject: local });
      dtls.role = 'client';
      remote.updateDtlsRole('server');
      send.dtlsParameters = dtls;
      first = false;
    }
    const media = local.media[idx];
    params.mid = String(media.mid);
    params.rtcp.cname = common.getCname({ offerMediaObject: media });
    params.msid = `stream-1 track-${kind}`;
    params.encodings = unified.getRtpEncodings({ offerMediaObject: media });
    const sectionIdx = remote.getNextMediaSectionIdx();
    remote.send({ offerMediaObject: media, reuseMid: sectionIdx.reuseMid, offerRtpParameters: params, answerRtpParameters: remoteParams, codecOptions });
    send.steps.push({
      kind,
      offerSdp,
      mediaIndex: idx,
      codecOptions: codecOptions ?? null,
      extra,
      expectNative: clone(native),
      expectExtended: clone(ext),
      // After `remote.send`, which adds the codec options (Opus FEC and DTX) to the parameters: the server is sent these.
      expectParams: clone(params),
      expectRemoteParams: clone(remoteParams),
      expectRemoteSdp: remote.getSdp(),
    });
  }

  // ───── receiving: real consumer parameters from a real producer
  const plain = await router.createPlainTransport({ listenInfo: { protocol: 'udp', ip: '127.0.0.1' }, rtcpMux: true, comedia: true });
  const mkProducer = async (kind, ssrc, ptRtx) => {
    const cap = router.rtpCapabilities.codecs.find((c) => c.kind === kind);
    const rtpParameters = { codecs: [{ mimeType: cap.mimeType, payloadType: cap.preferredPayloadType, clockRate: cap.clockRate, channels: cap.channels, parameters: cap.parameters ?? {}, rtcpFeedback: cap.rtcpFeedback ?? [] }], encodings: [{ ssrc }], rtcp: { cname: `peer-${kind}` } };
    return plain.produce({ kind, rtpParameters });
  };
  const aProd = await mkProducer('audio', 1111);
  const vProd = await mkProducer('video', 2222);
  const recvT = await router.createWebRtcTransport({ listenInfos: [{ protocol: 'udp', ip: '127.0.0.1' }], enableUdp: true });
  const recvParams = clone({ iceParameters: recvT.iceParameters, iceCandidates: recvT.iceCandidates, dtlsParameters: recvT.dtlsParameters });
  const consumers = [];
  for (const [kind, producer] of [['audio', aProd], ['video', vProd]]) {
    const c = await recvT.consume({ producerId: producer.id, rtpCapabilities: clone(recvCaps), paused: true });
    consumers.push({ kind, id: c.id, producerId: producer.id, rtpParameters: clone(c.rtpParameters) });
  }
  const recvRemote = new RemoteSdp({ ...clone(recvParams), sctpParameters: undefined });
  const recvDtlsRole = 'server';
  recvRemote.updateDtlsRole('client');
  const recv = { transportParams: recvParams, recvRtpCapabilities: clone(recvCaps), consumers, steps: [] };
  for (const [i, c] of consumers.entries()) {
    const mid = c.rtpParameters.mid ?? String(i);
    recvRemote.receive({ mid, kind: c.kind, offerRtpParameters: clone(c.rtpParameters), streamId: c.rtpParameters.rtcp?.cname ?? '-', trackId: c.id });
    recv.steps.push({ mid, consumer: i, expectRemoteOffer: recvRemote.getSdp() });
  }
  const final = recv.steps[recv.steps.length - 1].expectRemoteOffer;
  const { answer } = await answerTo(final);
  const answerObj = sdpTransform.parse(answer);
  for (const c of consumers) {
    const mid = c.rtpParameters.mid ?? String(consumers.indexOf(c));
    const m = answerObj.media.find((x) => String(x.mid) === mid);
    common.applyCodecParameters({ offerRtpParameters: clone(c.rtpParameters), answerMediaObject: m });
  }
  recv.answerSdp = answer;
  recv.expectDtls = common.extractDtlsParameters({ sdpObject: sdpTransform.parse(answer) });
  recv.expectDtls.role = 'client';
  recv.expectAnswerAfterCodecParameters = sdpTransform.write(answerObj);

  // ───── restart ICE: new parameters change every section
  const newIce = { usernameFragment: 'newufrag1', password: 'newpassword0123456789abcd', iceLite: true };
  remote.updateIceParameters(newIce);
  const restart = { iceParameters: newIce, expectRemoteSdp: remote.getSdp() };

  fs.writeFileSync(path.join(__dirname, '../../test/fixtures/mediasoup_golden.json'), JSON.stringify({ generated: 'by tool/golden/generate.cjs from mediasoup-client ' + require(path.join(SDK, 'client/web/node_modules/mediasoup-client/package.json')).version, routerRtpCapabilities: routerCaps, sdps, nativeCaps, extended, recvCaps, send, recv, restart }, null, 1));
  console.log('written');
  await worker.close();
  process.exit(0);
}
main().catch((e) => {
  console.error(e);
  process.exit(1);
});
