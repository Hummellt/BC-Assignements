// src/App.js
import React, { useEffect, useRef, useState } from "react";
import "./App.css";
import { create } from "kubo-rpc-client";
import { ethers } from "ethers";
import QRCode from "qrcode";
import QrScanner from "qr-scanner";

import logo from "./meetup_confirmation.png";
import { addresses, abis } from "./contracts";

// DEV fallback time (example)
const DEV_ALLOW_FALLBACK = true;
const DEV_FALLBACK_TIME = Math.floor(Date.now() / 1000) + 3600;

const ZERO_ADDRESS =
  "0x0000000000000000000000000000000000000000000000000000000000000000";

let client;

// ethers v5 – Browser Provider
const defaultProvider = new ethers.providers.Web3Provider(window.ethereum);

// MeetupContract mit IPFS-Proof (mapping address => string arrivalProofIPFS)
const meetupContract = new ethers.Contract(
  addresses.meetup,
  abis.meetup,
  defaultProvider
);

// Read the IPFS hash currently stored in the contract for the connected user
async function readCurrentUserIpfsHash() {
  const addr = await defaultProvider.getSigner().getAddress();
  const result = await meetupContract.arrivalProofIPFS(addr);
  console.log("arrivalProofIPFS for user:", result);
  return result;
}

function App() {
  const [ipfsHash, setIpfsHash] = useState("");
  const [status, setStatus] = useState("");
  const [myQrDataUrl, setMyQrDataUrl] = useState("");

  // meeting time only (location removed)
  const [meetingTimeHuman, setMeetingTimeHuman] = useState("");

  const [scannerActive, setScannerActive] = useState(false);
  const [scanResult, setScanResult] = useState("");
  const videoRef = useRef(null);
  const qrScannerRef = useRef(null);

  // Mutual attestation builder state
  const [otherAddressInput, setOtherAddressInput] = useState("");
  const [pendingMutual, setPendingMutual] = useState(null); // { a,b,ts,sigCallerForOther }
  const [mutualRequestQr, setMutualRequestQr] = useState(""); // dataURL showing request for other to scan
  const [mutualSigQr, setMutualSigQr] = useState(""); // dataURL where other shows signature back to caller

  // ask wallet access
  useEffect(() => {
    window.ethereum?.enable?.();
  }, []);

  //  IPFS HASH
  useEffect(() => {
    async function readFile() {
      try {
        const fileHash = await readCurrentUserIpfsHash();
        if (fileHash && fileHash !== "" && fileHash !== ZERO_ADDRESS) {
          setIpfsHash(fileHash);
        }
      } catch (e) {
        console.log("readCurrentUserIpfsHash error:", e.message);
      }
    }
    readFile();
  }, []);

  // read meeting time from the contract once on load (location removed)
  useEffect(() => {
    async function loadMeetingInfo() {
      try {
        const mt = await meetupContract.meetingTime();
        const mtNum = Number(mt.toString());

        if (mtNum) {
          setMeetingTimeHuman(new Date(mtNum * 1000).toLocaleString());
        } else if (DEV_ALLOW_FALLBACK) {
          setMeetingTimeHuman(new Date(DEV_FALLBACK_TIME * 1000).toLocaleString());
        }
      } catch (e) {
        console.warn("loadMeetingInfo failed:", e?.message ?? e);
        if (DEV_ALLOW_FALLBACK) {
          setMeetingTimeHuman(new Date(DEV_FALLBACK_TIME * 1000).toLocaleString());
        }
      }
    }
    loadMeetingInfo();
  }, []);

  // save IPFS-CID in Smart Contract as Arrival-Proof
  async function confirmArrivalOnChain(hash) {
    const signer = defaultProvider.getSigner();
    let signerAddr;
    try {
      signerAddr = await signer.getAddress();
    } catch (e) {
      console.error("Wallet/signature unavailable:", e);
      throw new Error("Wallet not connected. Open your wallet and connect the account.");
    }

    const contractWithSigner = meetupContract.connect(signer);

    // --- diagnostics: contract address / expected address / network ---
    try {
      const network = await defaultProvider.getNetwork();
      console.log("Provider network:", network);
    } catch (nerr) {
      console.warn("Could not read provider network:", nerr);
    }
    console.log("meetupContract.address:", meetupContract.address);
    console.log("addresses.meetup (expected):", addresses.meetup);

    // read on-chain state for sanity checks
    let participant1, participant2, meetingTime;
    try {
      [participant1, participant2, meetingTime] = await Promise.all([
        meetupContract.participant1(),
        meetupContract.participant2(),
        meetupContract.meetingTime(),
      ]);
    } catch (e) {
      console.error("Failed reading contract state:", e);
    }

    // ensure we compare strings
    const p1 = participant1 ? String(participant1) : null;
    const p2 = participant2 ? String(participant2) : null;

    console.log("Signer:", signerAddr);
    console.log("Participants:", p1, p2);
    console.log("MeetingTime (bn):", meetingTime?.toString());

    // basic checks
    if (p1 && p2) {
      const s = signerAddr.toLowerCase();
      if (s !== p1.toLowerCase() && s !== p2.toLowerCase()) {
        throw new Error("Connected account is not a participant in this meetup contract.");
      }
    }

    const now = Math.floor(Date.now() / 1000);
    if (meetingTime && Number(meetingTime.toString()) > now) {
      throw new Error("Meeting time not reached yet on-chain. confirmArrival requires block.timestamp >= meetingTime.");
    }

    const method =
      typeof contractWithSigner.confirmArrival === "function"
        ? "confirmArrival"
        : typeof contractWithSigner.confirmArrivalWithProof === "function"
        ? "confirmArrivalWithProof"
        : null;

    if (!method) {
      const msg = "Contract does not expose confirmArrival(...) or confirmArrivalWithProof(...)";
      console.error(msg, contractWithSigner);
      throw new Error(msg);
    }

    // Fetch attestation JSON from IPFS (public gateway fallback)
    let attestation;
    try {
      // try local HTTP gateway first (if running a local node), else public gateway
      const localUrl = `http://127.0.0.1:8080/ipfs/${hash}`;
      let res = await fetch(localUrl).catch(() => null);
      if (!res || !res.ok) {
        res = await fetch(`https://ipfs.io/ipfs/${hash}`);
      }
      if (!res || !res.ok) throw new Error("Failed to fetch attestation JSON from IPFS");
      attestation = await res.json();
    } catch (e) {
      console.error("Failed to fetch attestation JSON:", e);
      throw new Error("Could not retrieve attestation JSON from IPFS. Ensure the attestation is uploaded and CID is correct.");
    }

    // Expect attestation to contain the two attesters and signatures
    const { attester1, attester2, timestamp, signature1, signature2 } = attestation || {};
    if (!attester1 || !attester2 || !timestamp || !signature1 || !signature2) {
      console.error("Attestation missing required fields", attestation);
      throw new Error("Attestation JSON missing required fields: attester1, attester2, timestamp, signature1, signature2.");
    }

    // Basic on-chain sanity checks (ensure signer is participant)
    const p1Lower = participant1 ? String(participant1).toLowerCase() : null;
    const p2Lower = participant2 ? String(participant2).toLowerCase() : null;
    const s = signerAddr.toLowerCase();
    if (p1Lower && p2Lower && s !== p1Lower && s !== p2Lower) {
      throw new Error("Connected account is not a participant in this meetup contract.");
    }

    // call the strong-typed confirmArrival on-chain
    try {
      setStatus("Submitting attestation to contract…");
      const tx = await contractWithSigner.confirmArrival(
        attester1,
        attester2,
        Number(timestamp),
        signature1,
        signature2,
        hash
      );
      console.log("TX contract", tx.hash);
      await tx.wait();
      setIpfsHash(hash);
      setStatus("On-chain confirmation complete.");
    } catch (err) {
      console.error("confirmArrival transaction failed:", err);
      const reason =
        err?.error?.message ||
        err?.data?.message ||
        err?.message ||
        (typeof err === "string" ? err : JSON.stringify(err));
      throw new Error(`Transaction failed: ${reason}`);
    }
  }

  async function confirmMutualOnChainFromIpfsHash(hash) {
    const signer = defaultProvider.getSigner();
    let signerAddr;
    try {
      signerAddr = await signer.getAddress();
    } catch (e) {
      throw new Error("Wallet not connected. Open your wallet and connect the account.");
    }
    const contractWithSigner = meetupContract.connect(signer);

    // fetch attestation JSON
    let attestation;
    try {
      const localUrl = `http://127.0.0.1:8080/ipfs/${hash}`;
      let res = await fetch(localUrl).catch(() => null);
      if (!res || !res.ok) {
        res = await fetch(`https://ipfs.io/ipfs/${hash}`);
      }
      if (!res || !res.ok) throw new Error("Failed to fetch attestation JSON from IPFS");
      attestation = await res.json();
    } catch (e) {
      throw new Error("Could not retrieve attestation JSON from IPFS: " + (e?.message ?? e));
    }

    // Expect mutual attestation shape: { type: "mutual", a, b, timestamp, sigAForB, sigBForA }
    const { type, a, b, timestamp, sigAForB, sigBForA } = attestation || {};
    if (type !== "mutual" || !a || !b || !timestamp || !sigAForB || !sigBForA) {
      throw new Error("IPFS attestation is not a valid mutual attestation");
    }

    // Determine caller role and order signatures accordingly:
    const caller = signerAddr.toLowerCase();
    const aLower = String(a).toLowerCase();
    const bLower = String(b).toLowerCase();

    if (caller !== aLower && caller !== bLower) {
      throw new Error("Connected account is not part of the mutual attestation");
    }

    let other, sigOtherForCaller, sigCallerForOther;
    if (caller === aLower) {
      other = b;
      sigOtherForCaller = sigBForA;
      sigCallerForOther = sigAForB;
    } else {
      other = a;
      sigOtherForCaller = sigAForB;
      sigCallerForOther = sigBForA;
    }

    // call contract
    try {
      setStatus("Submitting mutual attestation to contract…");
      const tx = await contractWithSigner.confirmMutualArrival(
        other,
        Number(timestamp),
        sigOtherForCaller,
        sigCallerForOther,
        hash
      );
      await tx.wait();
      setIpfsHash(hash);
      setStatus("Mutual on-chain confirmation complete.");
    } catch (err) {
      const reason =
        err?.error?.message ||
        err?.data?.message ||
        err?.message ||
        (typeof err === "string" ? err : JSON.stringify(err));
      throw new Error("Transaction failed: " + reason);
    }
  }

  async function runDiagnostics() {
    try {
      const signer = defaultProvider.getSigner();
      const signerAddr = await signer.getAddress();
      console.log("Connected signer:", signerAddr);

      const [p1, p2, mt, depositAmount, contractBalance, ipfsForSigner] = await Promise.all([
        meetupContract.participant1().catch(() => null),
        meetupContract.participant2().catch(() => null),
        meetupContract.meetingTime().catch(() => null),
        meetupContract.depositAmount().catch(() => null),
        defaultProvider.getBalance(meetupContract.address).catch(() => null),
        meetupContract.arrivalProofIPFS(signerAddr).catch(() => ""),
      ]);

      console.log("participant1:", p1);
      console.log("participant2:", p2);
      console.log("meetingTime (bn):", mt?.toString());
      console.log("depositAmount (bn):", depositAmount?.toString());
      console.log("contract balance (wei):", contractBalance?.toString());
      console.log("arrivalProofIPFS for signer:", ipfsForSigner);
      console.log("meetupContract.address:", meetupContract.address);
      console.log("addresses.meetup (expected):", addresses.meetup);
      alert("Diagnostics logged to console.");
    } catch (e) {
      console.error("Diagnostics failed:", e);
      alert("Diagnostics failed: " + (e?.message ?? e));
    }
  }

  // Minimal QR generator: ephemeral payload + signature -> QR image
  async function generateMyQr() {
    try {
      const signer = defaultProvider.getSigner();
      const addr = await signer.getAddress();
      const ts = Math.floor(Date.now() / 1000);
      const payload = { address: addr, contract: addresses.meetup, ts };
      const sig = await signer.signMessage(JSON.stringify(payload));
      const qrContent = JSON.stringify({ payload, sig });
      const dataUrl = await QRCode.toDataURL(qrContent, { margin: 2, scale: 6 });
      setMyQrDataUrl(dataUrl);
    } catch (e) {
      console.error("QR generation failed", e);
      setStatus("QR generation failed: " + (e?.message ?? e));
    }
  }

  // Prepare a mutual-request QR (caller generates and signs their own piece)
  async function prepareMutualRequest(otherAddrInputVal) {
    try {
      setStatus("Preparing mutual request…");
      const signer = defaultProvider.getSigner();
      const caller = await signer.getAddress();
      const a = caller;
      const b = otherAddrInputVal;
      const ts = Math.floor(Date.now() / 1000);

      // compute digest where arriver = other (this caller's signature for other)
      const digestForCallerSigning = await meetupContract.hashMutualAttestation(b, a, ts);
      const sigCallerForOther = await signer.signMessage(ethers.utils.arrayify(digestForCallerSigning));

      const requestPayload = {
        type: "mutual-request",
        a,
        b,
        ts,
        sigCallerForOther,
      };

      const dataUrl = await QRCode.toDataURL(JSON.stringify(requestPayload), { margin: 2, scale: 6 });
      setMutualRequestQr(dataUrl);
      setPendingMutual({ a, b, ts, sigCallerForOther });
      setStatus("Mutual request prepared. Show this QR to the other participant so they can sign.");
    } catch (e) {
      console.error("prepareMutualRequest failed", e);
      setStatus("Failed preparing mutual request: " + (e?.message ?? e));
    }
  }

  // QR scanner: expects scanned content to be the attestation JSON (attester1, attester2, timestamp, signature1, signature2)
  async function processScannedContent(content) {
    setScanResult(content);
    setStatus("Processing scanned QR…");

    let parsed;
    try {
      parsed = JSON.parse(content);
    } catch (e) {
      // not JSON, treat as possible raw CID
      parsed = null;
    }

    try {
      if (!client) {
        client = create({ url: "http://127.0.0.1:5001/api/v0" });
      }

      // Handle mutual-request and mutual-sig flows (unchanged)
      if (parsed && parsed.type === "mutual-request") {
        const signer = defaultProvider.getSigner();
        const me = (await signer.getAddress()).toLowerCase();
        const aLower = String(parsed.a).toLowerCase();
        const bLower = String(parsed.b).toLowerCase();

        if (me === bLower) {
          setStatus("Mutual request received. Signing…");
          const digestCaller = await meetupContract.hashMutualAttestation(parsed.a, parsed.b, Number(parsed.ts));
          const sigOtherForCaller = await signer.signMessage(ethers.utils.arrayify(digestCaller));

          const sigPayload = {
            type: "mutual-sig",
            a: parsed.a,
            b: parsed.b,
            ts: parsed.ts,
            sigOtherForCaller,
          };

          const dataUrl = await QRCode.toDataURL(JSON.stringify(sigPayload), { margin: 2, scale: 6 });
          setMutualSigQr(dataUrl);
          setStatus("Signed mutual request. Show this QR to the original requester to finish.");
          return;
        } else {
          setStatus("Mutual request scanned but you are not the intended signer.");
          return;
        }
      }

      if (parsed && parsed.type === "mutual-sig") {
        const signer = defaultProvider.getSigner();
        const me = (await signer.getAddress()).toLowerCase();
        const aLower = String(parsed.a).toLowerCase();
        const bLower = String(parsed.b).toLowerCase();

        if (me === aLower) {
          if (!pendingMutual || pendingMutual.a.toLowerCase() !== aLower || pendingMutual.b.toLowerCase() !== bLower || Number(pendingMutual.ts) !== Number(parsed.ts)) {
            setStatus("No matching pending mutual request found. Please prepare a mutual request first.");
            return;
          }

          const attestation = {
            type: "mutual",
            a: pendingMutual.a,
            b: pendingMutual.b,
            timestamp: pendingMutual.ts,
            sigAForB: pendingMutual.sigCallerForOther,
            sigBForA: parsed.sigOtherForCaller,
          };

          const blob = new Blob([JSON.stringify(attestation)], { type: "application/json" });
          const res = await client.add(blob);
          const cidStr = res.cid.toString();
          setStatus("Uploaded mutual attestation to IPFS: " + cidStr);
          await confirmMutualOnChainFromIpfsHash(cidStr);
          setStatus("Mutual arrival confirmed on-chain via scanned attestation.");
          setPendingMutual(null);
          setMutualRequestQr("");
          setMutualSigQr("");
          return;
        } else {
          setStatus("Mutual signature scanned. If you are the original requester, prepare the mutual request first and then scan this signature.");
          return;
        }
      }

      let cidStr;
      if (parsed && typeof parsed === "object" && parsed.type === "mutual") {
        const blob = new Blob([JSON.stringify(parsed)], { type: "application/json" });
        const res = await client.add(blob);
        cidStr = res.cid.toString();
        setStatus("Uploaded mutual attestation to IPFS: " + cidStr);
        await confirmMutualOnChainFromIpfsHash(cidStr);
        setStatus("Mutual arrival confirmed on-chain via scanned attestation.");
        return;
      }

      if (parsed && typeof parsed === "object") {
        const blob = new Blob([JSON.stringify(parsed)], { type: "application/json" });
        const res = await client.add(blob);
        cidStr = res.cid.toString();
      } else {
        cidStr = content.trim();
      }

      setStatus("Uploading attestation / calling contract...");
      await confirmArrivalOnChain(cidStr);
      setStatus("Arrival confirmed on-chain via scanned attestation.");
    } catch (err) {
      console.error("Failed processing scanned QR:", err);
      setStatus("Error: " + (err?.message ?? String(err)));
    }
  }

  function startScanner() {
    if (!videoRef.current) return;
    setStatus("Starting camera for QR scanning...");
    qrScannerRef.current = new QrScanner(
      videoRef.current,
      (result) => {
        stopScanner();
        processScannedContent(result?.data ?? result);
      },
      {
        highlightScanRegion: true,
        returnDetailedScanResult: false,
      }
    );
    qrScannerRef.current.start().then(() => {
      setScannerActive(true);
      setStatus("Scanner active. Point camera at QR.");
    }).catch((e) => {
      console.error("Camera start failed", e);
      setStatus("Could not start camera: " + (e?.message ?? e));
    });
  }

  function stopScanner() {
    if (qrScannerRef.current) {
      qrScannerRef.current.stop();
      qrScannerRef.current.destroy();
      qrScannerRef.current = null;
    }
    setScannerActive(false);
    setStatus("Scanner stopped.");
  }

  useEffect(() => {
    return () => {
      if (qrScannerRef.current) {
        qrScannerRef.current.destroy();
        qrScannerRef.current = null;
      }
    };
  }, []);

  return (
    <div className="App">
      <header className="App-header">
        {/* Logo restored */}
        <div style={{ marginBottom: 12 }}>
          <img src={logo} alt="Meetup logo" style={{ height: 64, marginBottom: 8 }} />
        </div>

        {/* QR generation */}
        <div style={{ marginBottom: 12 }}>
          <button onClick={generateMyQr} className="btn" style={{ marginRight: 8 }}>
            Generate my QR
          </button>
          <span style={{ fontSize: 12, color: "#666" }}>Create an ephemeral signed QR for peers to scan.</span>
          {myQrDataUrl && (
            <div style={{ marginTop: 8 }}>
              <img src={myQrDataUrl} alt="My QR" style={{ maxWidth: 240, border: "1px solid #ddd", borderRadius: 6 }} />
            </div>
          )}
        </div>

        {/* Mutual attestation builder */}
        <div style={{ width: 560, maxWidth: "100%", background: "#fff", padding: 12, borderRadius: 8, marginBottom: 12 }}>
          <h3 style={{ margin: "0 0 8px 0", color: "#333" }}>Mutual Attestation</h3>
          <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
            <input
              placeholder="Other participant address (0x...)"
              value={otherAddressInput}
              onChange={(e) => setOtherAddressInput(e.target.value)}
              style={{ padding: 8, flex: "1 1 320px", borderRadius: 4, border: "1px solid #ccc" }}
            />
            <button
              className="btn"
              onClick={() => prepareMutualRequest(otherAddressInput)}
            >
              Prepare mutual request (sign & show QR)
            </button>
          </div>
          <div style={{ marginTop: 10 }}>
            <div style={{ fontSize: 13, color: "#333" }}>Flow (caller & other):</div>
            <ol style={{ fontSize: 13 }}>
              <li>Caller prepares mutual request and shows the generated QR to the other participant.</li>
              <li>Other scans the request QR; the app signs and shows a response QR (mutual-sig).</li>
              <li>Caller scans the response QR; the app uploads the attestation to IPFS and calls confirmMutualArrival on-chain.</li>
            </ol>
            <div style={{ marginTop: 8 }}>
              {mutualRequestQr && (
                <div>
                  <div style={{ fontSize: 12, color: "#666" }}>Mutual request QR (show to other):</div>
                  <img src={mutualRequestQr} alt="Mutual request QR" style={{ maxWidth: 240, border: "1px solid #ddd", borderRadius: 6 }} />
                </div>
              )}
              {mutualSigQr && (
                <div style={{ marginTop: 8 }}>
                  <div style={{ fontSize: 12, color: "#666" }}>Mutual signature QR (show back to caller):</div>
                  <img src={mutualSigQr} alt="Mutual signature QR" style={{ maxWidth: 240, border: "1px solid #ddd", borderRadius: 6 }} />
                </div>
              )}
            </div>
          </div>
        </div>

        {/* Meeting: only show time (location removed) */}
        <div style={{ width: 560, maxWidth: "100%", background: "#fff", padding: 12, borderRadius: 8, marginBottom: 12 }}>
          <h3 style={{ margin: "0 0 8px 0", color: "#333" }}>Meeting</h3>
          {meetingTimeHuman ? (
            <div style={{ display: "flex", gap: 12, alignItems: "flex-start", flexWrap: "wrap" }}>
              <div style={{ flex: "1 1 100%", minWidth: 180 }}>
                <div style={{ fontSize: 13, color: "#333" }}>Time</div>
                <div style={{ fontSize: 14, marginTop: 6, color: "#333" }}>{meetingTimeHuman}</div>
              </div>
            </div>
          ) : (
            <div>Loading meeting info…</div>
          )}
        </div>

        <p>
          Arrival is now handled via QR-attestations. Scan a QR containing the attestation JSON or an IPFS CID pointing to the attestation.
        </p>

        <div style={{ marginBottom: 12 }}>
          <button onClick={startScanner} className="btn" disabled={scannerActive} style={{ marginRight: 8 }}>
            Start QR Scanner
          </button>
          <button onClick={stopScanner} className="btn" disabled={!scannerActive}>
            Stop Scanner
          </button>
          <button type="button" className="btn" onClick={runDiagnostics} style={{ marginLeft: 8 }}>
            Run Diagnostics
          </button>
        </div>

        <div>
          <video ref={videoRef} style={{ width: 320, height: 240, border: "1px solid #ccc", borderRadius: 6 }} />
        </div>

        {status && <p>{status}</p>}
        {scanResult && <p>Last scan: {scanResult}</p>}
        {ipfsHash && <p>Last stored IPFS hash on-chain: {ipfsHash}</p>}
      </header>
    </div>
  );
}

export default App;
