"use client";

import { useState, useCallback } from "react";
import JSZip from "jszip";
import { Upload, FileArchive, CheckCircle2, AlertCircle, Loader2 } from "lucide-react";

interface Props {
  onFileSelect: (file: File | null) => void;
  disabled?: boolean;
}

export default function FileUploader({ onFileSelect, disabled }: Props) {
  const [file, setFile] = useState<File | null>(null);
  const [isValidating, setIsValidating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [dragActive, setDragActive] = useState(false);

  const validateAndroidProject = useCallback(async (zipFile: File) => {
    setIsValidating(true);
    setError(null);
    try {
      const zip = await JSZip.loadAsync(zipFile);
      const files = Object.keys(zip.files);

      const requiredFiles = ["gradlew", "gradlew.bat", "build.gradle", "settings.gradle"];
      // Check for .gradle.kts or .settings.gradle.kts as well
      const hasFile = (name: string) => files.some(f => f.endsWith(name) || f.endsWith(`${name}.kts`));

      const missing = requiredFiles.filter(f => !hasFile(f));

      if (missing.length > 0) {
        throw new Error("Structure de projet Android non détectée. Le ZIP doit contenir gradlew, gradlew.bat, build.gradle et settings.gradle.");
      }

      setFile(zipFile);
      onFileSelect(zipFile);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Erreur lors de l'analyse du fichier ZIP.");
      setFile(null);
      onFileSelect(null);
    } finally {
      setIsValidating(false);
    }
  }, [onFileSelect]);

  const handleDrop = useCallback((e: React.DragEvent) => {
    e.preventDefault();
    setDragActive(false);
    if (disabled) return;

    const droppedFile = e.dataTransfer.files?.[0];
    if (droppedFile && droppedFile.name.endsWith(".zip")) {
      validateAndroidProject(droppedFile);
    } else {
      setError("Veuillez sélectionner un fichier .zip valide.");
    }
  }, [disabled, validateAndroidProject]);

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const selectedFile = e.target.files?.[0];
    if (selectedFile) {
      validateAndroidProject(selectedFile);
    }
  };

  return (
    <div className={`space-y-4 ${disabled ? "opacity-50 pointer-events-none" : ""}`}>
      <div
        onDragOver={(e) => { e.preventDefault(); setDragActive(true); }}
        onDragLeave={() => setDragActive(false)}
        onDrop={handleDrop}
        className={`relative border-2 border-dashed rounded-xl p-8 flex flex-col items-center justify-center transition-all ${
          dragActive ? "border-blue-500 bg-blue-50 dark:bg-blue-900/20" : "border-gray-300 dark:border-gray-600 hover:border-gray-400"
        }`}
      >
        <input
          type="file"
          accept=".zip"
          onChange={handleFileChange}
          className="absolute inset-0 w-full h-full opacity-0 cursor-pointer"
        />

        {isValidating ? (
          <div className="flex flex-col items-center gap-2">
            <Loader2 className="w-10 h-10 animate-spin text-blue-500" />
            <p className="text-sm font-medium">Analyse du ZIP...</p>
          </div>
        ) : file ? (
          <div className="flex flex-col items-center gap-2">
            <div className="p-3 bg-green-100 dark:bg-green-900/30 rounded-full">
              <FileArchive className="w-10 h-10 text-green-600 dark:text-green-400" />
            </div>
            <p className="font-medium">{file.name}</p>
            <p className="text-xs text-gray-500">{(file.size / 1024 / 1024).toFixed(2)} Mo</p>
            <div className="flex items-center gap-1 text-green-600 text-sm mt-2">
              <CheckCircle2 className="w-4 h-4" />
              Projet Android valide
            </div>
          </div>
        ) : (
          <div className="flex flex-col items-center gap-2">
            <div className="p-3 bg-gray-100 dark:bg-gray-800 rounded-full">
              <Upload className="w-10 h-10 text-gray-500" />
            </div>
            <p className="font-medium">Glissez-déposez votre projet ZIP ici</p>
            <p className="text-xs text-gray-500">Ou cliquez pour parcourir les fichiers (max 100 Mo)</p>
          </div>
        )}
      </div>

      {error && (
        <div className="p-3 bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400 rounded-md flex items-start gap-2">
          <AlertCircle className="w-5 h-5 mt-0.5 flex-shrink-0" />
          <p className="text-sm">{error}</p>
        </div>
      )}
    </div>
  );
}
