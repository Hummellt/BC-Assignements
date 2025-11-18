// src/App.js
import React, { useEffect, useState } from "react";
import "./App.css";
import { create } from "kubo-rpc-client";
import { ethers } from "ethers";
import { Buffer } from "buffer";
import exifr from "exifr";

import logo from "./meetup_confirmation.png";
import { addresses, abis } from "./contracts";

// Coordinates on-chain are stored scaled by COORD_SCALE (microdegrees)
const COORD_SCALE = 1e6;
const MAX_DISTANCE_METERS = 200; // max distance from meeting point (meters)

// DEV fallback (example values)
const EXPECTED_LOCATION = {
  lat: 52.520008, // e.g., Berlin
  lon: 13.404954,
};

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

// ---- Helper functions for distance calculation ----
function deg2rad(deg) {
  return (deg * Math.PI) / 180;
}

function distanceMeters(lat1, lon1, lat2, lon2) {
  const R = 6371000; // Erdradius in Meter
  const dLat = deg2rad(lat2 - lat1);
  const dLon = deg2rad(lon2 - lon1);

  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(deg2rad(lat1)) *
      Math.cos(deg2rad(lat2)) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);

  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

// Read the IPFS hash currently stored in the contract for the connected user
async function readCurrentUserIpfsHash() {
  const addr = await defaultProvider.getSigner().getAddress();
  const result = await meetupContract.arrivalProofIPFS(addr);
  console.log("arrivalProofIPFS for user:", result);
  return result;
}

// EXIF stripping: draw image into a <canvas> and export a new JPEG without EXIF
async function stripExif(fileObj) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    const reader = new FileReader();

    reader.onload = (ev) => {
      img.onload = () => {
        const canvas = document.createElement("canvas");
        canvas.width = img.width;
        canvas.height = img.height;
        const ctx = canvas.getContext("2d");
        ctx.drawImage(img, 0, 0);

        canvas.toBlob(
          (blob) => {
            if (!blob) {
              return reject(new Error("Could not create cleaned image blob"));
            }
            resolve(blob);
          },
          "image/jpeg",
          0.95
        );
      };
      img.onerror = reject;
      img.src = ev.target.result;
    };

    reader.onerror = reject;
    reader.readAsDataURL(fileObj);
  });
}

// Small OpenStreetMap embed to show the meeting location
function MeetingMap({ lat, lon, zoom = 15, width = 320, height = 220 }) {
  if (lat == null || lon == null) return null;
  const delta = 0.02;
  const left = lon - delta;
  const bottom = lat - delta;
  const right = lon + delta;
  const top = lat + delta;
  const src = `https://www.openstreetmap.org/export/embed.html?bbox=${encodeURIComponent(
    left
  )}%2C${encodeURIComponent(bottom)}%2C${encodeURIComponent(right)}%2C${encodeURIComponent(
    top
  )}&layer=mapnik&marker=${encodeURIComponent(lat)}%2C${encodeURIComponent(lon)}`;

  return (
    <div style={{ marginTop: 8 }}>
      <div
        style={{
          width: width,
          height: height,
          border: "1px solid #ccc",
          borderRadius: 4,
          overflow: "hidden",
        }}
      >
        <iframe
          title="meeting-location"
          src={src}
          style={{ border: 0, width: "100%", height: "100%" }}
          loading="lazy"
        />
      </div>
    </div>
  );
}

function App() {
  const [ipfsHash, setIpfsHash] = useState("");
  const [file, setFile] = useState(null); // bereinigtes Bild (ohne EXIF) als Buffer
  const [locationOk, setLocationOk] = useState(false);
  const [gpsInfo, setGpsInfo] = useState(null);
  const [status, setStatus] = useState("");

  // meeting info from contract
  const [meetingLocation, setMeetingLocation] = useState(null);
  const [meetingTimeHuman, setMeetingTimeHuman] = useState("");

  const DEV_ALLOW_FALLBACK = true;
  const DEV_FALLBACK_MEETING = EXPECTED_LOCATION;
  const DEV_FALLBACK_TIME = Math.floor(Date.now() / 1000) + 3600;

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

  // read meeting coordinates + meeting time from the contract once on load
  useEffect(() => {
    async function loadMeetingInfo() {
      try {
        const [latScaled, lonScaled, mt] = await Promise.all([
          meetupContract.meetingLat(),
          meetupContract.meetingLon(),
          meetupContract.meetingTime(),
        ]);
        const latNum = Number(latScaled.toString());
        const lonNum = Number(lonScaled.toString());
        const mtNum = Number(mt.toString());

        if (latNum || lonNum) {
          setMeetingLocation({ lat: latNum / COORD_SCALE, lon: lonNum / COORD_SCALE });
        } else if (DEV_ALLOW_FALLBACK) {
          setMeetingLocation(DEV_FALLBACK_MEETING);
        }

        if (mtNum) {
          setMeetingTimeHuman(new Date(mtNum * 1000).toLocaleString());
        } else if (DEV_ALLOW_FALLBACK) {
          setMeetingTimeHuman(new Date(DEV_FALLBACK_TIME * 1000).toLocaleString());
        }
      } catch (e) {
        console.warn("loadMeetingInfo failed:", e?.message ?? e);
        if (DEV_ALLOW_FALLBACK) {
          setMeetingLocation(DEV_FALLBACK_MEETING);
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

    // --- NEW: diagnostics: contract address / expected address / network ---
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

    try {
      const tx = await contractWithSigner[method](hash);
      console.log("TX contract", tx.hash);
      await tx.wait();
      setIpfsHash(hash);
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

  // Datei-Upload + IPFS
  const handleSubmit = async (e) => {
    e.preventDefault();
    try {
      if (!file) {
        alert("Please choose a valid photo first.");
        return;
      }
      if (!locationOk) {
        alert("Location is not verified. Please choose a photo with correct GPS.");
        return;
      }

      setStatus("Uploading to IPFS…");

      if (!client) {
        // kubo-rpc-client: Browser-URL zur lokalen Kubo-Instanz
        client = create({ url: "http://127.0.0.1:5001/api/v0" });
      }

      const result = await client.add(file);

      // optional: im lokalen Node unter /<cid> erreichbar machen
      try {
        await client.files.cp(`/ipfs/${result.cid}`, `/${result.cid}`);
      } catch (e) {
        // ignore if files API not available
      }

      const cidStr = result.cid.toString();
      console.log("IPFS CID:", cidStr);

      setStatus("Writing CID to smart contract…");
      await confirmArrivalOnChain(cidStr);

      setStatus("Done ✔");
    } catch (error) {
      console.log(error);
      setStatus(`Error: ${error.message}`);
    }
  };

  // choose file, check Location, EXIF strippen
  const retrieveFile = async (e) => {
    const fileObj = e.target.files[0];
    if (!fileObj) return;

    try {
      setStatus("Reading EXIF data…");
      setLocationOk(false);
      setGpsInfo(null);

      // robust exif parsing: try parse with helpers and fallback to full parse
      let exif = null;
      try {
        // exifr can parse ArrayBuffer or File directly
        exif = await exifr.parse(fileObj).catch(() => null);
      } catch (err) {
        exif = null;
      }

      // normalize possible EXIF fields into decimal lat/lon
      const toDecimal = (val, ref) => {
        if (val == null) return null;
        if (Array.isArray(val)) {
          const [deg = 0, min = 0, sec = 0] = val;
          let dec = deg + min / 60 + sec / 3600;
          if (ref === "S" || ref === "W") dec = -dec;
          return dec;
        }
        if (typeof val === "number") return val;
        const n = Number(val);
        return Number.isFinite(n) ? n : null;
      };

      let lat = null;
      let lon = null;
      if (exif) {
        const latRaw = exif.latitude ?? exif.gpsLatitude ?? exif.GPSLatitude;
        const lonRaw = exif.longitude ?? exif.gpsLongitude ?? exif.GPSLongitude;
        const latRef = exif.GPSLatitudeRef ?? exif.gpsLatitudeRef;
        const lonRef = exif.GPSLongitudeRef ?? exif.gpsLongitudeRef;
        lat = toDecimal(latRaw, latRef);
        lon = toDecimal(lonRaw, lonRef);
      }

      if (lat == null || lon == null) {
        alert("No GPS info found in the image EXIF. Upload aborted.");
        setStatus("No GPS info in image.");
        return;
      }

      setGpsInfo({ lat, lon });

      // choose target location: on-chain meetingLocation if available, otherwise fallback
      const target = meetingLocation ?? EXPECTED_LOCATION;
      const dist = distanceMeters(lat, lon, target.lat, target.lon);
      console.log("Image coords", { lat, lon }, "target", target, "distance m", dist);

      if (dist > MAX_DISTANCE_METERS) {
        alert(
          `Image is too far from meetup location (~${Math.round(
            dist
          )} m). Max allowed: ${MAX_DISTANCE_METERS} m.`
        );
        setStatus("Location check failed.");
        setLocationOk(false);
        return;
      }

      setLocationOk(true);
      setStatus(`Location OK (~${Math.round(dist)} m). Stripping EXIF…`);

      // EXIF stripping and convert to Buffer 
      const cleanedBlob = await stripExif(fileObj);
      const cleanedArrayBuffer = await cleanedBlob.arrayBuffer();
      const cleanedBuffer = Buffer.from(cleanedArrayBuffer);
      setFile(cleanedBuffer);

      setStatus("Ready to upload cleaned image to IPFS.");
    } catch (err) {
      console.log(err);
      setStatus(`Error while reading EXIF: ${err.message ?? err}`);
      setLocationOk(false);
    }
  };

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

  return (
    <div className="App">
      <header className="App-header">

        {/* Meeting box: map, coordinates and time */}
        <div style={{ width: 560, maxWidth: "100%", background: "#fff", padding: 12, borderRadius: 8, marginBottom: 12 }}>
          <h3 style={{ margin: "0 0 8px 0", color: "#333" }}>Meeting</h3>
          {meetingLocation ? (
            <div style={{ display: "flex", gap: 12, alignItems: "flex-start", flexWrap: "wrap" }}>
              <div style={{ flex: "0 0 240px", minWidth: 200 }}>
                <MeetingMap lat={meetingLocation.lat} lon={meetingLocation.lon} width={240} height={140} />
              </div>
              <div style={{ flex: "1 1 260px", minWidth: 180 }}>
                <div style={{ fontSize: 13, color: "#333" }}>Coordinates</div>
                <div style={{ fontSize: 14, marginTop: 6, color: "#333" }}>
                  {meetingLocation.lat.toFixed(6)}, {meetingLocation.lon.toFixed(6)}
                </div>
                <div style={{ marginTop: 10, fontSize: 13, color: "#333" }}>Time</div>
                <div style={{ fontSize: 14, marginTop: 6, color: "#333" }}>{meetingTimeHuman}</div>
              </div>
            </div>
          ) : (
            <div>Loading meeting info…</div>
          )}
        </div>

        <p>
          Upload a photo as arrival evidence. GPS is checked against the meetup
          location, EXIF is stripped, and the cleaned image is stored on IPFS.
        </p>

        <form className="form" onSubmit={handleSubmit}>
          <input type="file" name="data" accept="image/*" onChange={retrieveFile} />
          <button type="submit" className="btn">
            Upload & Confirm Arrival
          </button>
          <button type="button" className="btn" onClick={runDiagnostics} style={{ marginLeft: 8 }}>
            Run Diagnostics
          </button>
        </form>

        {status && <p>{status}</p>}

        {gpsInfo && (
          <p>
            Detected GPS: lat {gpsInfo.lat.toFixed(5)}, lon {gpsInfo.lon.toFixed(5)}
          </p>
        )}

        {ipfsHash && <p>Last stored IPFS hash on-chain: {ipfsHash}</p>}
      </header>
    </div>
  );
}

export default App;
