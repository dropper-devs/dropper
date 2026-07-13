"use client";

import { useActionState, useEffect, useRef } from "react";
import {
  subscribeAction,
  type SubscribeActionState,
} from "@/app/actions";
import { analytics } from "@/lib/analytics";

const INITIAL_STATE: SubscribeActionState = { kind: "idle" };

export default function SubscribeForm() {
  const [status, formAction, pending] = useActionState(
    subscribeAction,
    INITIAL_STATE,
    "/#updates",
  );
  const trackedSubmission = useRef<string | null>(null);

  useEffect(() => {
    if (
      status.kind === "ok" &&
      status.submissionId !== trackedSubmission.current
    ) {
      trackedSubmission.current = status.submissionId;
      // The write has succeeded on the server; analytics remains optional.
      analytics.track("Email Subscribed");
    }
  }, [status]);

  const inputKey =
    status.kind === "idle" ? "initial" : status.submissionId;

  return (
    <form className="subscribe-form" action={formAction} noValidate>
      <label className="hp-field" aria-hidden="true">
        Leave this field empty
        <input type="text" name="website" tabIndex={-1} autoComplete="off" />
      </label>
      <input
        key={inputKey}
        type="email"
        name="email"
        required
        defaultValue={status.kind === "err" ? status.email : undefined}
        placeholder="you@example.com"
        aria-label="Email address"
        disabled={pending}
      />
      <button
        type="submit"
        className="btn btn-primary"
        disabled={pending}
      >
        {pending ? "Signing up…" : "Get updates"}
      </button>
      <p
        className={`form-status ${
          status.kind === "ok" ? "ok" : status.kind === "err" ? "err" : ""
        }`}
        role="status"
        aria-live="polite"
        style={{ width: "100%" }}
      >
        {status.kind === "ok" || status.kind === "err" ? status.message : ""}
      </p>
    </form>
  );
}
