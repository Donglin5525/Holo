import WebSocket from "ws";
import { randomUUID } from "node:crypto";

import { GatewayError } from "../errors.js";

export function createDashScopeAsrProvider(config) {
  return {
    async transcribe(input) {
      if (!config.dashscopeApiKey) {
        throw new GatewayError("UPSTREAM_AUTH_FAILED", "DashScope API key is not configured", 503);
      }

      const pcm = extractPCM(input.audio);
      if (pcm.byteLength === 0) {
        throw new GatewayError("EMPTY_TRANSCRIPT", "Audio is empty", 400);
      }

      const transcript = await transcribeWithWebSocket(config, pcm, input.locale);
      return {
        text: transcript,
        provider: "dashscope",
        duration: null,
        confidence: null,
      };
    },
  };
}

function transcribeWithWebSocket(config, audio, locale) {
  return new Promise((resolve, reject) => {
    const url = `${config.dashscopeWebSocketURL}?model=${encodeURIComponent(config.model)}`;
    const socket = new WebSocket(url, {
      headers: {
        authorization: `Bearer ${config.dashscopeApiKey}`,
      },
    });
    const timeout = setTimeout(() => {
      socket.close();
      reject(new GatewayError("UPSTREAM_TIMEOUT", "DashScope ASR timed out", 504));
    }, 60_000);

    let isResolved = false;

    function finish(error, value) {
      if (isResolved) return;
      isResolved = true;
      clearTimeout(timeout);
      socket.close();
      if (error) {
        reject(error);
      } else {
        resolve(value);
      }
    }

    socket.on("open", () => {
      // Wait for session.created before sending session.update.
    });

    socket.on("message", (data) => {
      let event;
      try {
        event = JSON.parse(data.toString("utf8"));
      } catch {
        return;
      }

      if (event.type === "error") {
        finish(new GatewayError("MODEL_UNAVAILABLE", event.error?.message ?? "DashScope ASR error", 503));
        return;
      }

      if (event.type === "session.created") {
        socket.send(JSON.stringify(sessionUpdatePayload(config, locale)));
        return;
      }

      if (event.type === "session.updated") {
        for (const chunk of chunkAudio(audio)) {
          socket.send(JSON.stringify({
            event_id: eventID(),
            type: "input_audio_buffer.append",
            audio: Buffer.from(chunk).toString("base64"),
          }));
        }
        socket.send(JSON.stringify(eventPayload("input_audio_buffer.commit")));
        socket.send(JSON.stringify(eventPayload("session.finish")));
        return;
      }

      if (event.type === "conversation.item.input_audio_transcription.completed") {
        const transcript = String(event.transcript ?? "").trim();
        if (!transcript) {
          finish(new GatewayError("EMPTY_TRANSCRIPT", "Empty transcript", 422));
          return;
        }
        finish(null, transcript);
        return;
      }

      if (event.type === "conversation.item.input_audio_transcription.failed") {
        finish(new GatewayError("MODEL_UNAVAILABLE", event.error?.message ?? "DashScope ASR failed", 503));
        return;
      }

      if (event.type === "session.finished") {
        finish(new GatewayError("EMPTY_TRANSCRIPT", "No transcript returned", 422));
      }
    });

    socket.on("error", () => {
      finish(new GatewayError("MODEL_UNAVAILABLE", "DashScope ASR network error", 503));
    });
  });
}

function sessionUpdatePayload(config, locale) {
  return {
    event_id: eventID(),
    type: "session.update",
    session: {
      input_audio_format: "pcm",
      sample_rate: config.sampleRate,
      input_audio_transcription: {
        language: normalizedLanguage(locale ?? config.language),
      },
      turn_detection: null,
    },
  };
}

function eventPayload(type) {
  return {
    event_id: eventID(),
    type,
  };
}

function normalizedLanguage(locale) {
  const value = String(locale ?? "zh").trim().toLowerCase();
  if (value.startsWith("zh")) return "zh";
  if (value.startsWith("en")) return "en";
  return value || "zh";
}

function chunkAudio(audio, chunkSize = 3200) {
  const chunks = [];
  for (let offset = 0; offset < audio.byteLength; offset += chunkSize) {
    chunks.push(audio.slice(offset, Math.min(offset + chunkSize, audio.byteLength)));
  }
  return chunks;
}

function extractPCM(arrayBuffer) {
  const buffer = Buffer.from(arrayBuffer);
  if (buffer.length <= 44 || buffer.subarray(0, 4).toString("ascii") !== "RIFF") {
    return buffer;
  }

  let index = 12;
  while (index + 8 <= buffer.length) {
    const chunkID = buffer.subarray(index, index + 4).toString("ascii");
    const chunkSize = buffer.readUInt32LE(index + 4);
    const dataStart = index + 8;
    const dataEnd = dataStart + chunkSize;

    if (chunkID === "data" && dataEnd <= buffer.length) {
      return buffer.subarray(dataStart, dataEnd);
    }

    index = dataEnd + (chunkSize % 2);
  }

  return buffer.subarray(44);
}

function eventID() {
  return `event_${randomUUID().replaceAll("-", "")}`;
}
