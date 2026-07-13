"use client"

import { useState } from "react"
import Reveal from "@/components/Reveal"

const STEPS = [
  {
    title: "See what you’ll need",
    description: "A free account, R2’s free tier, and about three minutes.",
    image: "/wizard/1.png",
    alt: "Dropper setup introduction listing the three things needed",
  },
  {
    title: "Sign in to Cloudflare",
    description: "Create a free account or use the one you already have.",
    image: "/wizard/2.png",
    alt: "Dropper wizard step for creating or signing in to a Cloudflare account",
  },
  {
    title: "Enable R2 storage",
    description: "The wizard opens the right dashboard page. One click turns it on.",
    image: "/wizard/3.png",
    alt: "Dropper wizard step for enabling Cloudflare R2 storage",
  },
  {
    title: "Paste one token",
    description: "Dropper creates the bucket, enables its public URL, and configures itself.",
    image: "/wizard/4.png",
    alt: "Dropper wizard API token step where the app completes its configuration",
  },
] as const

function Arrow({ direction }: { direction: "left" | "right" }) {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true">
      <path
        d={direction === "left" ? "M12.5 4.5 7 10l5.5 5.5" : "m7.5 4.5 5.5 5.5-5.5 5.5"}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function BenefitIcon({ kind }: { kind: "clock" | "check" | "lock" }) {
  return (
    <span aria-hidden="true">
      <svg viewBox="0 0 20 20">
        {kind === "clock" && (
          <>
            <circle cx="10" cy="10" r="6.5" />
            <path d="M10 6.5v3.8l2.5 1.5" />
          </>
        )}
        {kind === "check" && <path d="m5.5 10.2 2.7 2.7 6.2-6.2" />}
        {kind === "lock" && (
          <>
            <rect x="5.5" y="8.5" width="9" height="6.8" rx="1.6" />
            <path d="M7.4 8.5V6.9a2.6 2.6 0 0 1 5.2 0v1.6" />
          </>
        )}
      </svg>
    </span>
  )
}

export default function SetupWizard() {
  const [activeStep, setActiveStep] = useState(0)
  const step = STEPS[activeStep]

  return (
    <section id="setup" className="setup-wizard-section">
      <div className="container">
        <Reveal>
          <div className="setup-wizard-heading">
            <p className="section-kicker">Easy setup</p>
            <h2 className="section-title">We&apos;ll help you get set up.</h2>
            <p className="section-lede">
              Dropper&apos;s setup wizard walks you through Cloudflare, so you
              don&apos;t need to know the ins and outs. Paste one API token and
              Dropper handles the rest.
            </p>
            <ul className="setup-wizard-promises" aria-label="Setup benefits">
              <li>
                <BenefitIcon kind="clock" />
                About three minutes
              </li>
              <li>
                <BenefitIcon kind="check" />
                No R2 experience needed
              </li>
              <li>
                <BenefitIcon kind="lock" />
                Token stored in Keychain
              </li>
            </ul>
          </div>
        </Reveal>

        <Reveal delay={100}>
          <div className="setup-wizard-stage">
            <div className="setup-wizard-preview">
              <a
                className="setup-wizard-screen"
                href={step.image}
                target="_blank"
                rel="noopener noreferrer"
                aria-label={`Open step ${activeStep + 1} screenshot at full size`}
              >
                {/* These UI captures must stay lossless. A plain img bypasses
                    Next's WebP conversion and serves the original PNG. */}
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img
                  key={step.image}
                  src={step.image}
                  alt={step.alt}
                  width={500}
                  height={673}
                  loading="lazy"
                  decoding="async"
                />
                <span className="setup-wizard-zoom">View full size</span>
              </a>
              <div className="setup-wizard-preview-footer">
                <p aria-live="polite">
                  <span>Step {activeStep + 1} of {STEPS.length}</span>
                  {step.title}
                </p>
                <div className="setup-wizard-arrows">
                  <button
                    type="button"
                    onClick={() => setActiveStep(activeStep - 1)}
                    disabled={activeStep === 0}
                    aria-label="Previous setup step"
                  >
                    <Arrow direction="left" />
                  </button>
                  <button
                    type="button"
                    onClick={() => setActiveStep(activeStep + 1)}
                    disabled={activeStep === STEPS.length - 1}
                    aria-label="Next setup step"
                  >
                    <Arrow direction="right" />
                  </button>
                </div>
              </div>
            </div>

            <div className="setup-wizard-guide">
              <ol className="setup-wizard-steps" aria-label="Dropper setup steps">
                {STEPS.map((item, index) => (
                  <li key={item.image}>
                    <button
                      type="button"
                      className={index === activeStep ? "active" : undefined}
                      onClick={() => setActiveStep(index)}
                      aria-current={index === activeStep ? "step" : undefined}
                    >
                      <span className="setup-wizard-number">{index + 1}</span>
                      <span className="setup-wizard-step-copy">
                        <strong>{item.title}</strong>
                        <span>{item.description}</span>
                      </span>
                    </button>
                  </li>
                ))}
              </ol>

              <div className="setup-wizard-done">
                <span className="setup-wizard-check" aria-hidden="true">✓</span>
                <p>
                  <strong>That&apos;s the whole setup.</strong> After this,
                  sharing is just drop, paste, done.
                </p>
              </div>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  )
}
