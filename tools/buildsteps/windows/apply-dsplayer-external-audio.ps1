$ErrorActionPreference = 'Stop'

function Replace-Once([string]$Path, [string]$Old, [string]$New, [string]$Name) {
    $text = Get-Content -Raw $Path
    if ($text.Contains($New)) { return }
    if (-not $text.Contains($Old)) { throw "Anchor not found: $Name" }
    $text = $text.Replace($Old, $New)
    Set-Content -Path $Path -Value $text -Encoding UTF8 -NoNewline
}

$h = 'xbmc/cores/DSPlayer/StreamsManager.h'
Replace-Once $h `
'  uint32_t                m_iSampleRate; ///< Audio samplerate' `
('  uint32_t                m_iSampleRate; ///< Audio samplerate' + "`r`n" + '  bool                    m_external = false; ///< External audio sidecar') `
'StreamsManager.h external flag'

Replace-Once $h `
'  void LoadStreams();' `
('  void LoadStreams();' + "`r`n`r`n" + '  /// Discover and add Kodi external audio files after the DirectShow graph is complete' + "`r`n" + '  void LoadExternalAudio();') `
'StreamsManager.h LoadExternalAudio declaration'

$cpp = 'xbmc/cores/DSPlayer/StreamsManager.cpp'
Replace-Once $cpp `
'  : m_strCodecName(""), m_iBitRate(0), m_iSampleRate(0)' `
'  : m_strCodecName(""), m_iBitRate(0), m_iSampleRate(0), m_external(false)' `
'audio constructor'

Replace-Once $cpp `
'  if (m_pIAMStreamSelect)' `
('  if (m_pIAMStreamSelect && !m_audioStreams[disableIndex]->m_external' + "`r`n" + '      && !m_audioStreams[enableIndex]->m_external)' + "`r`n" + '  {') `
'IAMStreamSelect external guard'

$function = @'

void CStreamsManager::LoadExternalAudio()
{
  if (!m_init || m_audioStreams.empty() || !m_pGraphBuilder)
    return;

  std::vector<std::string> audioFiles;
  CUtil::ScanForExternalAudio(g_application.CurrentFile(), audioFiles);
  if (audioFiles.empty())
    return;

  const auto& audioPath = audioFiles.front();
  std::string sourcePath = CDSFile::SmbToUncPath(audioPath);
  if (StringUtils::StartsWithNoCase(sourcePath, "special://"))
    sourcePath = CSpecialProtocol::TranslatePath(sourcePath);

  std::wstring sourcePathW;
  g_charsetConverter.utf8ToW(sourcePath, sourcePathW);

  Com::SComPtr<IBaseFilter> sourceFilter;
  HRESULT hr = m_pGraphBuilder->AddSourceFilter(sourcePathW.c_str(), L"DSPlayer External Audio", &sourceFilter);
  if (FAILED(hr) || !sourceFilter)
  {
    CLog::Log(LOGWARNING, "{} Failed to add external audio source '{}' (0x{:08X})",
              __FUNCTION__, audioPath.c_str(), static_cast<unsigned>(hr));
    return;
  }

  Com::SComPtr<IPin> audioPin;
  AM_MEDIA_TYPE* audioMediaType = nullptr;

  BeginEnumPins(sourceFilter, pEP, pPin)
  {
    PIN_DIRECTION direction;
    if (FAILED(pPin->QueryDirection(&direction)) || direction != PINDIR_OUTPUT)
      continue;

    BeginEnumMediaTypes(pPin, pET, pMediaType)
    {
      if (pMediaType->majortype == MEDIATYPE_Audio)
      {
        audioPin = pPin;
        audioMediaType = CreateMediaType(pMediaType);
        break;
      }
    }
    EndEnumMediaTypes(pMediaType)

    if (audioPin)
      break;
  }
  EndEnumPins

  if (!audioPin || !audioMediaType)
  {
    CLog::Log(LOGWARNING, "{} No audio output found in external file '{}'",
              __FUNCTION__, audioPath.c_str());
    m_pGraphBuilder->RemoveFilter(sourceFilter);
    return;
  }

  auto* external = new CDSStreamDetailAudio();
  MediaTypeToStreamDetail(audioMediaType, *external);
  DeleteMediaType(audioMediaType);

  external->pObj = audioPin;
  external->pUnk = nullptr;
  external->flags = 0;
  external->connected = false;
  external->m_external = true;
  external->displayname = StringUtils::Format("External: {}", URIUtils::GetFileName(audioPath));

  const int index = static_cast<int>(m_audioStreams.size());
  m_audioStreams.push_back(external);

  CLog::Log(LOGINFO, "{} External audio stream found: {}", __FUNCTION__, audioPath.c_str());
  SetAudioStream(index);
}
'@

$loadAnchor = "  SubtitleManager->SetSubtitleVisible(CMediaSettings::GetInstance().GetCurrentVideoSettings().m_SubtitleOn);`r`n}`r`n`r`nint CStreamsManager::GetSubtitle()"
$cppText = Get-Content -Raw $cpp
if (-not $cppText.Contains('void CStreamsManager::LoadExternalAudio()')) {
    if (-not $cppText.Contains($loadAnchor)) { throw 'LoadStreams insertion anchor not found' }
    $insert = "  SubtitleManager->SetSubtitleVisible(CMediaSettings::GetInstance().GetCurrentVideoSettings().m_SubtitleOn);`r`n}`r`n" + $function + "`r`nint CStreamsManager::GetSubtitle()"
    $cppText = $cppText.Replace($loadAnchor, $insert)
    Set-Content -Path $cpp -Value $cppText -Encoding UTF8 -NoNewline
}

$player = 'xbmc/cores/DSPlayer/DSPlayer.cpp'
Replace-Once $player `
'    if (CStreamsManager::Get()) CStreamsManager::Get()->SelectBestAudio();' `
('    if (CStreamsManager::Get()) CStreamsManager::Get()->SelectBestAudio();' + "`r`n" + '    if (CStreamsManager::Get()) CStreamsManager::Get()->LoadExternalAudio();') `
'DSPlayer.cpp LoadExternalAudio call'

Write-Host 'DSPlayer external-audio source changes applied.'
