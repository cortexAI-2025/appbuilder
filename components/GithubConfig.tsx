"use client";

import { useState } from "react";
import { GithubSettings, validateRepository } from "@/lib/github";
import { Github, CheckCircle2, XCircle, Loader2 } from "lucide-react";

interface Props {
  onConfigSave: (settings: GithubSettings) => void;
}

export default function GithubConfig({ onConfigSave }: Props) {
  const [token, setToken] = useState("");
  const [ownerRepo, setOwnerRepo] = useState("");
  const [isValidating, setIsValidating] = useState(false);
  const [status, setStatus] = useState<{ type: "success" | "error"; message: string } | null>(null);

  const handleValidate = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsValidating(true);
    setStatus(null);

    const [owner, repo] = ownerRepo.split("/");
    if (!owner || !repo) {
      setStatus({ type: "error", message: "Format invalide. Utilisez owner/repo" });
      setIsValidating(false);
      return;
    }

    const settings = { token, owner, repo };
    const result = await validateRepository(settings);

    if (result.success) {
      setStatus({ type: "success", message: "Connexion réussie !" });
      onConfigSave(settings);
    } else {
      setStatus({ type: "error", message: `Erreur: ${result.error}` });
    }
    setIsValidating(false);
  };

  return (
    <div className="bg-white dark:bg-gray-800 p-6 rounded-xl shadow-sm border border-gray-200 dark:border-gray-700">
      <div className="flex items-center gap-2 mb-4">
        <Github className="w-5 h-5 text-blue-600" />
        <h2 className="text-xl font-semibold">Configuration GitHub</h2>
      </div>
      <form onSubmit={handleValidate} className="space-y-4">
        <div>
          <label className="block text-sm font-medium mb-1">Personal Access Token (PAT)</label>
          <input
            type="password"
            value={token}
            onChange={(e) => setToken(e.target.value)}
            placeholder="ghp_xxxxxxxxxxxx"
            className="w-full p-2 border rounded-md dark:bg-gray-900 dark:border-gray-600 focus:ring-2 focus:ring-blue-500 outline-none"
            required
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Repository (Owner/Repo)</label>
          <input
            type="text"
            value={ownerRepo}
            onChange={(e) => setOwnerRepo(e.target.value)}
            placeholder="ex: user/my-android-app"
            className="w-full p-2 border rounded-md dark:bg-gray-900 dark:border-gray-600 focus:ring-2 focus:ring-blue-500 outline-none"
            required
          />
        </div>
        <button
          type="submit"
          disabled={isValidating}
          className="w-full bg-blue-600 hover:bg-blue-700 text-white font-medium py-2 px-4 rounded-md transition-colors disabled:opacity-50 flex items-center justify-center gap-2"
        >
          {isValidating ? (
            <>
              <Loader2 className="w-4 h-4 animate-spin" />
              Vérification...
            </>
          ) : (
            "Valider la connexion"
          )}
        </button>
      </form>

      {status && (
        <div
          className={`mt-4 p-3 rounded-md flex items-center gap-2 ${
            status.type === "success" ? "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400" : "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"
          }`}
        >
          {status.type === "success" ? <CheckCircle2 className="w-4 h-4" /> : <XCircle className="w-4 h-4" />}
          <span className="text-sm">{status.message}</span>
        </div>
      )}
    </div>
  );
}
