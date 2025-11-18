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

function App() {
  const [ipfsHash, setIpfsHash] = useState("");
  const [file, setFile] = useState(null); // bereinigtes Bild (ohne EXIF) als Buffer
  const [locationOk, setLocationOk] = useState(false);
  const [gpsInfo, setGpsInfo] = useState(null);
  const [status, setStatus] = useState("");

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

  // save IPFS-CID in Smart Contract as Arrival-Proof
  async function confirmArrivalOnChain(hash) {
    const contractWithSigner = meetupContract.connect(defaultProvider.getSigner());
    const tx = await contractWithSigner.confirmArrivalWithProof(hash);
    console.log("TX contract", tx.hash);
    await tx.wait();
    setIpfsHash(hash);
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

      const arrayBuffer = await fileObj.arrayBuffer();
      const exif = await exifr.parse(arrayBuffer, [
        "gpsLatitude",
        "gpsLongitude",
      ]);

      if (!exif || exif.gpsLatitude == null || exif.gpsLongitude == null) {
        alert("No GPS info found in this image.");
        setStatus("No GPS info in image.");
        return;
      }

      const lat = exif.gpsLatitude;
      const lon = exif.gpsLongitude;
      setGpsInfo({ lat, lon });

      const dist = distanceMeters(
        lat,
        lon,
        EXPECTED_LOCATION.lat,
        EXPECTED_LOCATION.lon
      );
      console.log("Distance to meetup (m):", dist);

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
      setStatus(
        `Location OK (~${Math.round(
          dist
        )} m from meetup). Stripping EXIF…`
      );

      // EXIF stripping und in Buffer umwandeln
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

  return (
    <div className="App">
      <header className="App-header">
        <img src={logo} className="App-logo" alt="logo" />
        <p>
          Upload a photo as arrival evidence. GPS is checked against the meetup
          location, EXIF is stripped, and the cleaned image is stored on IPFS.
        </p>

        <form className="form" onSubmit={handleSubmit}>
          <input type="file" name="data" accept="image/*" onChange={retrieveFile} />
          <button type="submit" className="btn">
            Upload & Confirm Arrival
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
