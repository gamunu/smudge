// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

enum ScanFixtures {
    /// /Scan/ScanCaps read from the DeskJet Ink Advantage 2336 over USB.
    static let scanCaps2336 = #"""
<?xml version="1.0" encoding="UTF-8"?>
<!-- THIS DATA SUBJECT TO DISCLAIMER(S) INCLUDED WITH THE PRODUCT OF ORIGIN. -->
<ScanCaps xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="http://www.hp.com/schemas/imaging/con/cnx/scan/2008/08/19">
	<DeviceCaps>
		<ModelName>DeskJet Ink Advantage 2300 All-in-One Printer series</ModelName>
		<DerivativeNumber>35</DerivativeNumber>
	</DeviceCaps>
	<ColorEntries>
		<ColorEntry>
			<ColorType>K1</ColorType>
			<Formats>
				<Format>Raw</Format>
			</Formats>
			<ImageTransforms>
				<ImageTransform>ToneMap</ImageTransform>
				<ImageTransform>Sharpening</ImageTransform>
				<ImageTransform>BwThreshold</ImageTransform>
			</ImageTransforms>
			<GrayRenderings>
				<GrayRendering>NTSC</GrayRendering>
			</GrayRenderings>
		</ColorEntry>
		<ColorEntry>
			<ColorType>Gray8</ColorType>
			<Formats>
				<Format>Raw</Format>
				<Format>Jpeg</Format>
			</Formats>
			<ImageTransforms>
				<ImageTransform>ToneMap</ImageTransform>
				<ImageTransform>Sharpening</ImageTransform>
			</ImageTransforms>
			<GrayRenderings>
				<GrayRendering>NTSC</GrayRendering>
			</GrayRenderings>
		</ColorEntry>
		<ColorEntry>
			<ColorType>Color8</ColorType>
			<Formats>
				<Format>Raw</Format>
				<Format>Jpeg</Format>
			</Formats>
			<ImageTransforms>
				<ImageTransform>ToneMap</ImageTransform>
				<ImageTransform>Sharpening</ImageTransform>
			</ImageTransforms>
		</ColorEntry>
	</ColorEntries>
	<Platen>
		<InputSourceCaps>
			<MinWidth>8</MinWidth>
			<MinHeight>8</MinHeight>
			<MaxWidth>2550</MaxWidth>
			<MaxHeight>3508</MaxHeight>
			<RiskyLeftMargin>34</RiskyLeftMargin>
			<RiskyRightMargin>34</RiskyRightMargin>
			<RiskyTopMargin>42</RiskyTopMargin>
			<RiskyBottomMargin>45</RiskyBottomMargin>
			<MinResolution>75</MinResolution>
			<MaxOpticalXResolution>1200</MaxOpticalXResolution>
			<MaxOpticalYResolution>1200</MaxOpticalYResolution>
			<SupportedResolutions>
				<Resolution>
					<XResolution>75</XResolution>
					<YResolution>75</YResolution>
					<NumCcd>1</NumCcd>
					<ColorTypes>
						<ColorType>K1</ColorType>
						<ColorType>Gray8</ColorType>
						<ColorType>Color8</ColorType>
					</ColorTypes>
				</Resolution>
				<Resolution>
					<XResolution>100</XResolution>
					<YResolution>100</YResolution>
					<NumCcd>1</NumCcd>
					<ColorTypes>
						<ColorType>K1</ColorType>
						<ColorType>Gray8</ColorType>
						<ColorType>Color8</ColorType>
					</ColorTypes>
				</Resolution>
				<Resolution>
					<XResolution>200</XResolution>
					<YResolution>200</YResolution>
					<NumCcd>1</NumCcd>
					<ColorTypes>
						<ColorType>K1</ColorType>
						<ColorType>Gray8</ColorType>
						<ColorType>Color8</ColorType>
					</ColorTypes>
				</Resolution>
				<Resolution>
					<XResolution>300</XResolution>
					<YResolution>300</YResolution>
					<NumCcd>1</NumCcd>
					<ColorTypes>
						<ColorType>K1</ColorType>
						<ColorType>Gray8</ColorType>
						<ColorType>Color8</ColorType>
					</ColorTypes>
				</Resolution>
				<Resolution>
					<XResolution>600</XResolution>
					<YResolution>600</YResolution>
					<NumCcd>1</NumCcd>
					<ColorTypes>
						<ColorType>K1</ColorType>
						<ColorType>Gray8</ColorType>
						<ColorType>Color8</ColorType>
					</ColorTypes>
				</Resolution>
				<Resolution>
					<XResolution>1200</XResolution>
					<YResolution>1200</YResolution>
					<NumCcd>1</NumCcd>
					<ColorTypes>
						<ColorType>K1</ColorType>
						<ColorType>Gray8</ColorType>
						<ColorType>Color8</ColorType>
					</ColorTypes>
				</Resolution>
			</SupportedResolutions>
		</InputSourceCaps>
	</Platen>
</ScanCaps>
"""#

    /// ScanSettings Image Capture sent for a default scan in the spike.
    static let imageCaptureSettings = Data(#"<?xml version="1.0" encoding="UTF-8"?><scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"><pwg:Version>2.0</pwg:Version><scan:Intent>TextAndGraphic</scan:Intent><pwg:ScanRegions pwg:MustHonor="true"><pwg:ScanRegion><pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits><pwg:Width>2480</pwg:Width><pwg:Height>3508</pwg:Height><pwg:XOffset>0</pwg:XOffset><pwg:YOffset>0</pwg:YOffset></pwg:ScanRegion></pwg:ScanRegions><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat><pwg:InputSource>Platen</pwg:InputSource><scan:ColorMode>RGB24</scan:ColorMode><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:ScanSettings>"#.utf8)
}
