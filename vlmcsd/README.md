# OpenWRT vlmcsd

- 自动跟踪 [上游](https://github.com/tfslabs/vlmcsd) 最新源码


You can see the following table to know which version of KMS host can activate which client [(Source from Microsoft Learn)](https://learn.microsoft.com/en-us/windows-server/get-started/kms-activation-planning?tabs=server25#activation-versions)

| CSVLK group | CSVLK can be hosted on | Windows editions activated by this KMS host |
| ------------- | ------------- | --- |
| Volume License for Windows Server 2025 |  up to Windows Server 2025¹ | up to Windows Server 2025 (all editions)<br>Windows 11 Enterprise LTSC 2024 |


## Volume License Management Service Limitation
```
$ ./vlmcs -x
You may use these product names or numbers:

  1 = Windows Vista Business                                                        127 = Windows Server 2022 Standard
  2 = Windows Vista Business N                                                      128 = Windows Server 2022 Datacenter
  3 = Windows Vista Enterprise                                                      129 = Windows Server 2022 Datacenter: Azure Edition
  4 = Windows Vista Enterprise N                                                    130 = Windows Server 2022 Standard (SAC)
  5 = Windows 7 Enterprise                                                          131 = Windows Server 2022 Datacenter (SAC)
  6 = Windows 7 Enterprise E                                                        132 = Windows Server 2025 Standard
  7 = Windows 7 Enterprise N                                                        133 = Windows Server 2025 Datacenter
  8 = Windows 7 Professional                                                        134 = Windows Server 2025 Datacenter: Azure Edition
  9 = Windows 7 Professional E                                                      135 = Office Professional Plus 2010
 10 = Windows 7 Professional N                                                      136 = Office Small Business Basics 2010
 11 = Windows 7 Embedded POSReady                                                   137 = Office Standard 2010
 12 = Windows 7 Embedded Standard                                                   138 = Office Access 2010
 13 = Windows 7 ThinPC                                                              139 = Office Excel 2010
 14 = Windows 8 Core                                                                140 = Office Groove 2010
 15 = Windows 8 Core Country Specific                                               141 = Office InfoPath 2010                                                          
 16 = Windows 8 Core N                                                              142 = Office Mondo 1 2010
 17 = Windows 8 Core Single Language                                                143 = Office Mondo 2 2010
 18 = Windows 8 Core ARM                                                            144 = Office OneNote 2010
 19 = Windows 8 Professional WMC                                                    145 = Office OutLook 2010
 20 = Windows 8 Embedded Industry Professional                                      146 = Office PowerPoint 2010
 21 = Windows 8 Embedded Industry Enterprise                                        147 = Office Project Pro 2010
 22 = Windows 8 Enterprise                                                          148 = Office Project Standard 2010
 23 = Windows 8 Enterprise N                                                        149 = Office Publisher 2010
 24 = Windows 8 Professional                                                        150 = Office Visio Premium 2010
 25 = Windows 8 Professional N                                                      151 = Office Visio Pro 2010
 26 = Windows 8.1 Core                                                              152 = Office Visio Standard 2010
 27 = Windows 8.1 Core ARM                                                          153 = Office Word 2010
 28 = Windows 8.1 Core Country Specific                                             154 = Office Professional Plus 2013 (Preview)                                       
 29 = Windows 8.1 Core N                                                            155 = Office Access 2013 (Preview)
 30 = Windows 8.1 Core Single Language                                              156 = Office Excel 2013 (Preview)
 31 = Windows 8.1 Professional Student                                              157 = Office Groove 2013 (Preview)
 32 = Windows 8.1 Professional Student N                                            158 = Office InfoPath 2013 (Preview)
 33 = Windows 8.1 Professional WMC                                                  159 = Office Lync 2013 (Preview)
 34 = Windows 8.1 Core Connected                                                    160 = Office Mondo 2013 (Preview)
 35 = Windows 8.1 Core Connected Country Specific                                   161 = Office OneNote 2013 (Preview)
 36 = Windows 8.1 Core Connected N                                                  162 = Office Outlook 2013 (Preview)
 37 = Windows 8.1 Core Connected Single Language                                    163 = Office PowerPoint 2013 (Preview)
 38 = Windows 8.1 Enterprise                                                        164 = Office Project Pro 2013 (Preview)
 39 = Windows 8.1 Enterprise N                                                      165 = Office Project Standard 2013 (Preview)
 40 = Windows 8.1 Professional                                                      166 = Office Publisher 2013 (Preview)
 41 = Windows 8.1 Professional N                                                    167 = Office Visio Pro 2013 (Preview)
 42 = Windows 8.1 Embedded Industry Professional                                    168 = Office Visio Standard 2013 (Preview)
 43 = Windows 8.1 Embedded Industry Automotive                                      169 = Office Word 2013 (Preview)
 44 = Windows 8.1 Embedded Industry Enterprise                                      170 = Office Professional Plus 2013
 45 = Windows 10/11 Home                                                            171 = Office Standard 2013
 46 = Windows 10/11 Home Preview                                                    172 = Office Access 2013
 47 = Windows 10/11 Home Country Specific                                           173 = Office Excel 2013
 48 = Windows 10/11 Home Country Specific Preview                                   174 = Office InfoPath 2013
 49 = Windows 10/11 Home N                                                          175 = Office Lync 2013
 50 = Windows 10/11 Home N Preview                                                  176 = Office Mondo 2013
 51 = Windows 10/11 Home Single Language                                            177 = Office OneNote 2013
 52 = Windows 10 Enterprise 2015 LTSB S                                             178 = Office OutLook 2013
 53 = Windows 10 Enterprise 2015 LTSB SN                                            179 = Office PowerPoint 2013
 54 = Windows 10 Enterprise 2016 LTSB S                                             180 = Office Project Pro 2013
 55 = Windows 10 Enterprise 2016 LTSB SN                                            181 = Office Project Standard 2013
 56 = Windows 10 Enterprise LTSC (2019, 2021)/Windows 11 Enterprise LTSC 2024 S     182 = Office Publisher 2013
 57 = Windows 10 Enterprise LTSC (2019, 2021)/Windows 11 Enterprise LTSC 2024 SN    183 = Office Visio Pro 2013
 58 = Windows 10/11 Enterprise for Virtual Desktops                                 184 = Office Visio Standard 2013
 59 = Windows 10/11 S (Lean)                                                        185 = Office Word 2013
 60 = Windows 10/11 SE                                                              186 = Office Standard 2016
 61 = Windows 10/11 SE N                                                            187 = Office Professional Plus 2016
 62 = Windows 10/11 Education                                                       188 = Office Access 2016
 63 = Windows 10/11 Education N                                                     189 = Office Excel 2016
 64 = Windows 10/11 Professional                                                    190 = Office Mondo 2016
 65 = Windows 10/11 Professional N                                                  191 = Office Mondo R 2016
 66 = Windows 10/11 Professional Education                                          192 = Office OneNote 2016
 67 = Windows 10/11 Professional Education N                                        193 = Office Outlook 2016
 68 = Windows 10/11 Professional Workstation                                        194 = Office Powerpoint 2016
 69 = Windows 10/11 Professional Workstation N                                      195 = Office Project Pro 2016
 70 = Windows 10/11 Enterprise                                                      196 = Office Project Pro 2016 C2R
 71 = Windows 10/11 Enterprise Preview                                              197 = Office Project Standard 2016
 72 = Windows 10/11 Enterprise N                                                    198 = Office Project Standard 2016 C2R
 73 = Windows 10/11 Enterprise N Preview                                            199 = Office Publisher 2016
 74 = Windows 10/11 Enterprise S Preview                                            200 = Office Skype for Business 2016
 75 = Windows 10/11 Enterprise SN Preview                                           201 = Office Visio Pro 2016
 76 = Windows 10/11 Enterprise for Virtual Desktops Preview                         202 = Office Visio Pro 2016 C2R
 77 = Windows IoT Enterprise LTSC (2021, 2024)                                      203 = Office Visio Standard 2016
 78 = Windows 10/11 Enterprise G                                                    204 = Office Visio Standard 2016 C2R
 79 = Windows 10/11 Enterprise G N                                                  205 = Office Word 2016
 80 = Windows 8/10 Preview Enterprise                                               206 = Office Standard 2019
 81 = Windows 8/10 Preview Professional                                             207 = Office Professional Plus 2019
 82 = Windows 8/10 Preview ProfessionalWMC                                          208 = Office Professional Plus 2019 Preview
 83 = Windows 8/10 Preview Core                                                     209 = Office Access 2019
 84 = Windows 8/10 Preview CoreARM                                                  210 = Office Excel 2019
 85 = Windows Server 2008 Web                                                       211 = Office Outlook 2019
 86 = Windows Server 2008 Compute Cluster                                           212 = Office Powerpoint 2019
 87 = Windows Server 2008 Standard                                                  213 = Office Project Pro 2019
 88 = Windows Server 2008 Standard without Hyper-V                                  214 = Office Project Pro 2019 Preview
 89 = Windows Server 2008 Enterprise                                                215 = Office Project Standard 2019
 90 = Windows Server 2008 Enterprise without Hyper-V                                216 = Office Publisher 2019
 91 = Windows Server 2008 Datacenter                                                217 = Office Skype for Business 2019
 92 = Windows Server 2008 Datacenter without Hyper-V                                218 = Office Visio Pro 2019
 93 = Windows Server 2008 Enterprise for Itanium                                    219 = Office Visio Pro 2019 Preview
 94 = Windows MultiPoint Server 2010                                                220 = Office Visio Standard 2019
 95 = Windows Server 2008 R2 Web                                                    221 = Office Word 2019
 96 = Windows Server 2008 R2 HPC Edition                                            222 = Office LTSC Professional Plus 2021
 97 = Windows Server 2008 R2 Standard                                               223 = Office LTSC Professional Plus 2021 Preview
 98 = Windows Server 2008 R2 Enterprise                                             224 = Office LTSC Standard 2021
 99 = Windows Server 2008 R2 Datacenter                                             225 = Office Access LTSC 2021
100 = Windows Server 2008 R2 Enterprise for Itanium                                 226 = Office Excel LTSC 2021
101 = Windows Server 2012 Essentials                                                227 = Office Outlook LTSC 2021
102 = Windows Server 2012 Datacenter                                                228 = Office Powerpoint LTSC 2021
103 = Windows Server 2012 Standard                                                  229 = Office Project Pro 2021
104 = Windows Server 2012 MultiPoint Premium                                        230 = Office Project Pro 2021 Preview
105 = Windows Server 2012 MultiPoint Standard                                       231 = Office Project Standard 2021
106 = Windows Server 2012 R2 Next Standard                                          232 = Office Publisher LTSC 2021
107 = Windows Server 2012 R2 Next Web                                               233 = Office Skype for Business LTSC 2021
108 = Windows Server 2012 R2 Essentials                                             234 = Office Visio LTSC Pro 2021
109 = Windows Server 2012 R2 Datacenter                                             235 = Office Visio LTSC Pro 2021 Preview
110 = Windows Server 2012 R2 Standard                                               236 = Office Visio LTSC Standard 2021
111 = Windows Server 2012 R2 Cloud Storage                                          237 = Office Word LTSC 2021
112 = Windows Server 2016 Azure Core                                                238 = Office LTSC Professional Plus 2024
113 = Windows Server 2016 Essentials                                                239 = Office LTSC Professional Plus 2024 Preview
114 = Windows Server 2016 Datacenter                                                240 = Office LTSC Standard 2024
115 = Windows Server 2016 Standard                                                  241 = Office Access LTSC 2024
116 = Windows Server 2016 ARM64                                                     242 = Office Excel LTSC 2024
117 = Windows Server 2016 Datacenter (SAC)                                          243 = Office Outlook LTSC 2024
118 = Windows Server 2016 Standard (SAC)                                            244 = Office PowerPoint LTSC 2024
119 = Windows Server 2016 Cloud Storage                                             245 = Office Project Pro LTSC 2024
120 = Windows Server 2019 Azure Core                                                246 = Office Project Pro LTSC 2024 Preview
121 = Windows Server 2019 Essentials                                                247 = Office Project Standard LTSC 2024
122 = Windows Server 2019 Datacenter                                                248 = Office Skype for Business LTSC 2024
123 = Windows Server 2019 Standard                                                  249 = Office Visio LTSC Pro 2024
124 = Windows Server 2019 ARM64                                                     250 = Office Visio LTSC Pro 2024 Preview                                            
125 = Windows Server 2019 Datacenter (SAC)                                          251 = Office Visio LTSC Standard 2024
126 = Windows Server 2019 Standard (SAC)                                            252 = Office Word LTSC 2024
```
