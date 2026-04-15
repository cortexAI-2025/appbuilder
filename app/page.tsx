"use client";

import { useState } from "react";
import GithubConfig from "@/components/GithubConfig";
import FileUploader from "@/components/FileUploader";
import BuildStatus from "@/components/BuildStatus";
import { GithubSettings, uploadProjectZip, triggerWorkflow } from "@/lib/github";
import { Box, Smartphone, Loader2, Rocket, AlertCircle } from "lucide-react";

export default function Home() {
  const [settings, setSettings] = useState<GithubSettings | null>(null);
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [isUploading, setIsUploading] = useState(false);
  const [isBuilding, setIsBuilding] = useState(false);
  const [signRelease, setSignRelease] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleStartBuild = async (type: "apk" | "aab") => {
    if (!settings || !selectedFile) return;

    setError(null);
    setIsUploading(true);

    const uploadResult = await uploadProjectZip(settings, selectedFile);
    if (!uploadResult.success) {
      setError(`Erreur lors de l'upload: ${uploadResult.error}`);
      setIsUploading(false);
      return;
    }

    const triggerResult = await triggerWorkflow(settings, type, signRelease);
    if (!triggerResult.success) {
      setError(`Erreur lors du déclenchement du workflow: ${triggerResult.error}`);
      setIsUploading(false);
      return;
    }

    setIsUploading(false);
    setIsBuilding(true);
  };

  return (
    <div className="min-h-screen bg-gray-50 dark:bg-gray-900 text-gray-900 dark:text-gray-100 py-12 px-4 sm:px-6 lg:px-8">
      <div className="max-w-3xl mx-auto space-y-8">
        <header className="text-center">
          <h1 className="text-4xl font-extrabold tracking-tight text-blue-600 dark:text-blue-500 flex items-center justify-center gap-3">
            <Rocket className="w-10 h-10" />
            The Hybrid Android Builder
          </h1>
          <p className="mt-2 text-lg text-gray-600 dark:text-gray-400">
            Compilez vos projets Android via GitHub Actions en un clic.
          </p>
        </header>

        <GithubConfig onConfigSave={setSettings} />

        <div className={`space-y-6 ${!settings ? "opacity-50 pointer-events-none" : ""}`}>
          <div className="bg-white dark:bg-gray-800 p-6 rounded-xl shadow-sm border border-gray-200 dark:border-gray-700">
            <h2 className="text-xl font-semibold mb-4">Projet Android</h2>
            <FileUploader onFileSelect={setSelectedFile} disabled={isUploading || isBuilding} />

            <div className="mt-4 flex items-center gap-2">
              <input
                type="checkbox"
                id="signRelease"
                checked={signRelease}
                onChange={(e) => setSignRelease(e.target.checked)}
                disabled={isUploading || isBuilding}
                className="w-4 h-4 text-blue-600 bg-gray-100 border-gray-300 rounded focus:ring-blue-500 dark:focus:ring-blue-600 dark:ring-offset-gray-800 focus:ring-2 dark:bg-gray-700 dark:border-gray-600"
              />
              <label htmlFor="signRelease" className="text-sm font-medium text-gray-700 dark:text-gray-300">
                Signer les artifacts (nécessite les secrets KEYSTORE_* configurés)
              </label>
            </div>

            <div className="mt-8 grid grid-cols-1 sm:grid-cols-2 gap-4">
              <button
                onClick={() => handleStartBuild("apk")}
                disabled={!selectedFile || isUploading || isBuilding}
                className="flex items-center justify-center gap-2 bg-blue-600 hover:bg-blue-700 text-white font-bold py-3 px-6 rounded-xl transition-all disabled:opacity-50 shadow-lg shadow-blue-500/20"
              >
                {isUploading ? (
                  <Loader2 className="w-5 h-5 animate-spin" />
                ) : (
                  <Smartphone className="w-5 h-5" />
                )}
                Compiler en APK
              </button>
              <button
                onClick={() => handleStartBuild("aab")}
                disabled={!selectedFile || isUploading || isBuilding}
                className="flex items-center justify-center gap-2 bg-indigo-600 hover:bg-indigo-700 text-white font-bold py-3 px-6 rounded-xl transition-all disabled:opacity-50 shadow-lg shadow-indigo-500/20"
              >
                {isUploading ? (
                  <Loader2 className="w-5 h-5 animate-spin" />
                ) : (
                  <Box className="w-5 h-5" />
                )}
                Compiler en AAB
              </button>
            </div>
          </div>
        </div>

        {error && (
          <div className="p-4 bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400 rounded-xl flex items-center gap-3 border border-red-200 dark:border-red-800">
            <AlertCircle className="w-6 h-6 flex-shrink-0" />
            <p className="font-medium">{error}</p>
          </div>
        )}

        {settings && (
          <BuildStatus
            settings={settings}
            isBuilding={isBuilding}
            onBuildComplete={() => setIsBuilding(false)}
          />
        )}
      </div>
    </div>
  );
}
