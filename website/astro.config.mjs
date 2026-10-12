// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// Served from GitHub Pages at ishangavidusha.github.io/transcribe_cpp, so every
// page lives under the repository's name.
export default defineConfig({
	site: 'https://ishangavidusha.github.io',
	base: '/transcribe_cpp',
	integrations: [
		starlight({
			title: 'transcribe_cpp',
			description:
				'Offline, on-device speech-to-text for Flutter. Hands-free dictation on iOS and Android, with no network and no API keys.',
			logo: { src: './src/assets/logo.svg' },
			favicon: '/favicon.svg',
			customCss: ['./src/styles/theme.css'],
			social: [
				{ icon: 'github', label: 'GitHub', href: 'https://github.com/ishangavidusha/transcribe_cpp' },
			],
			editLink: {
				baseUrl: 'https://github.com/ishangavidusha/transcribe_cpp/edit/main/website/',
			},
			sidebar: [
				{ label: 'Getting started', slug: 'getting-started' },
				{
					label: 'Guides',
					items: [
						{ slug: 'guides/models' },
						{ slug: 'guides/microphone' },
						{ slug: 'guides/your-own-audio' },
						{ slug: 'guides/background' },
						{ slug: 'guides/tuning' },
					],
				},
				{
					label: 'Concepts',
					items: [{ slug: 'concepts/how-it-works' }],
				},
				{
					label: 'Reference',
					items: [
						{ slug: 'reference/platforms' },
						{ slug: 'reference/performance' },
						{ slug: 'reference/troubleshooting' },
						{
							label: 'API reference',
							link: 'https://pub.dev/documentation/transcribe_cpp/latest/',
							attrs: { target: '_blank' },
						},
					],
				},
				{
					label: 'Contributing',
					items: [{ slug: 'contributing/building' }],
				},
			],
		}),
	],
});
