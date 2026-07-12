// Pronunciation assessment (§4.3.2): Azure Speech Pronunciation Assessment.
// The only major API with phoneme-level Japanese scoring (§1.3). Returns overall
// + fluency/prosody + per-phoneme scores → honest, phoneme-level grading (R5/R10).
//
// Requires AZURE_SPEECH_KEY and AZURE_SPEECH_REGION — either missing → 503.
//
// Data retention (§8.2): Azure Speech audio/transcription logging is OFF by
// default; keep it off (do not enable the "Logging"/"audit" options on the
// resource). Record the choice in COMPLIANCE.md.

import {
  ProviderNotConfiguredError,
  ProviderError,
  type AdapterDeps,
  type ProviderSpec,
  type PronAdapter,
  type PronPhoneme,
  type PronRequest,
  type PronResult,
} from "./types.ts";

function azurePron(spec: ProviderSpec, deps: AdapterDeps): PronAdapter {
  const key = deps.env.AZURE_SPEECH_KEY;
  const region = deps.env.AZURE_SPEECH_REGION;
  if (!key || !region) throw new ProviderNotConfiguredError("pron", "azure");
  // spec.model carries a default locale ("ja-JP"); the request locale wins.

  return {
    provider: "azure",
    async assess(req: PronRequest): Promise<PronResult> {
      const locale = req.locale || spec.model || "ja-JP";
      const config = {
        ReferenceText: req.referenceText,
        GradingSystem: "HundredMark",
        Granularity: "Phoneme",
        Dimension: "Comprehensive",
      };
      const paConfig = Buffer.from(JSON.stringify(config), "utf8").toString("base64");
      const url =
        `https://${region}.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1` +
        `?language=${encodeURIComponent(locale)}&format=detailed`;
      const res = await deps.fetchImpl(url, {
        method: "POST",
        headers: {
          "Ocp-Apim-Subscription-Key": key,
          "Pronunciation-Assessment": paConfig,
          "content-type": "audio/wav; codecs=audio/pcm; samplerate=16000",
          accept: "application/json",
        },
        body: req.audio,
      });
      if (!res.ok) throw new ProviderError("azure", res.status, `azure pron failed: ${res.status}`);
      const data = (await res.json()) as {
        Duration?: number;
        NBest?: {
          PronunciationAssessment?: { PronScore?: number; AccuracyScore?: number; FluencyScore?: number; ProsodyScore?: number };
          Words?: { Phonemes?: { Phoneme?: string; PronunciationAssessment?: { AccuracyScore?: number } }[] }[];
        }[];
      };
      const nbest = data.NBest?.[0];
      const pa = nbest?.PronunciationAssessment ?? {};
      const phonemes: PronPhoneme[] = [];
      for (const w of nbest?.Words ?? []) {
        for (const p of w.Phonemes ?? []) {
          phonemes.push({ phoneme: p.Phoneme ?? "", score: p.PronunciationAssessment?.AccuracyScore ?? 0 });
        }
      }
      return {
        overall: pa.PronScore ?? pa.AccuracyScore ?? 0,
        fluency: pa.FluencyScore,
        prosody: pa.ProsodyScore,
        phonemes,
        provider: "azure",
        // Azure Duration is in 100-ns ticks.
        durationSeconds: data.Duration ? data.Duration / 1e7 : undefined,
      };
    },
  };
}

export function defaultPronAdapter(spec: ProviderSpec, deps: AdapterDeps): PronAdapter {
  switch (spec.provider) {
    case "azure":
      return azurePron(spec, deps);
    default:
      throw new Error(`unknown pron provider: ${spec.provider}`);
  }
}
